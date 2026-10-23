defmodule IkeEmails.Invoicing do
  @moduledoc """
  The invoices (expenses) and their PDFs, and what they are matched to in the
  bank transactions.
  """

  import Ecto.Query, warn: false

  require Logger

  alias IkeEmails.Banking.Transaction
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Money
  alias IkeEmails.Repo
  alias IkeEmails.Storage

  @max_pdf_bytes 20_000_000
  @pdf_url_ttl 300

  def max_pdf_bytes, do: @max_pdf_bytes

  @doc """
  Invoices, newest first, with their transactions. `:search` matches the issuer
  name or the invoice number.
  """
  def list_invoices(opts \\ []) do
    Invoice
    |> search(opts[:search])
    |> order_by([i], desc: i.date, desc: i.id)
    |> preload(:transactions)
    |> Repo.all()
  end

  defp search(query, term) when is_binary(term) do
    case String.trim(term) do
      "" ->
        query

      term ->
        pattern = "%" <> String.replace(term, ~r/[\\%_]/, "\\\\\\0") <> "%"
        where(query, [i], ilike(i.issuer_name, ^pattern) or ilike(i.number, ^pattern))
    end
  end

  defp search(query, _term), do: query

  def get_invoice!(id) do
    Invoice |> Repo.get!(id) |> Repo.preload(:transactions)
  end

  @doc """
  A new invoice with what the transaction suggests: the amount and currency it
  was charged in (a foreign currency shows in its `conversion_details`), and the
  date the money was spent.
  """
  def new_invoice_for(%Transaction{} = transaction) do
    {amount_input, currency} =
      case Regex.run(~r/^\s*(\d[\d.,]*)\s+([A-Z]{3})\s*$/, transaction.conversion_details || "") do
        [_, amount, currency] ->
          {amount, currency}

        nil ->
          cents = transaction.amount |> Money.cents_from_decimal() |> abs()
          {Money.format_input(cents), "EUR"}
      end

    %Invoice{amount_input: amount_input, currency: currency, date: transaction.value_date}
  end

  @doc """
  A changeset for the invoice form, with the amount shown as it is typed.
  """
  def change_invoice(%Invoice{} = invoice, attrs \\ %{}) do
    invoice |> Invoice.with_amount_input() |> Invoice.changeset(attrs)
  end

  @doc """
  Stores the PDF and the invoice, and links the invoice to the given
  `:transaction_ids`, if any.

  Errors: a changeset, `:not_a_pdf`, `:too_large`, `{:duplicate, invoice}` when
  the same PDF was uploaded before, `:unknown_transaction` and
  `{:storage, reason}`.
  """
  def create_invoice(attrs, pdf, file_name, opts \\ []) when is_binary(pdf) do
    transaction_ids = Keyword.get(opts, :transaction_ids, [])
    file = file_facts(pdf, file_name)
    changeset = Invoice.create_changeset(%Invoice{}, attrs, file)

    with :ok <- check_pdf(pdf),
         :ok <- check_new(file.file_sha256),
         {:ok, changeset} <- apply_valid(changeset),
         :ok <- store(file, pdf) do
      insert_invoice(changeset, transaction_ids, file)
    end
  end

  defp file_facts(pdf, file_name) do
    sha256 = :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)

    %{
      file_key: "invoices/#{sha256}.pdf",
      file_name:
        file_name |> Path.basename() |> String.codepoints() |> Enum.take(255) |> Enum.join(),
      file_size: byte_size(pdf),
      file_sha256: sha256
    }
  end

  defp check_pdf(pdf) when byte_size(pdf) > @max_pdf_bytes, do: {:error, :too_large}
  defp check_pdf("%PDF-" <> _), do: :ok
  defp check_pdf(_), do: {:error, :not_a_pdf}

  defp check_new(sha256) do
    case Repo.get_by(Invoice, file_sha256: sha256) do
      nil -> :ok
      invoice -> {:error, {:duplicate, Repo.preload(invoice, :transactions)}}
    end
  end

  defp apply_valid(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}

  defp apply_valid(changeset) do
    {:error, %{changeset | action: :insert}}
  end

  defp store(file, pdf) do
    case Storage.put(file.file_key, pdf, "application/pdf") do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp insert_invoice(changeset, transaction_ids, file) do
    result =
      Repo.transact(fn ->
        with {:ok, invoice} <- Repo.insert(changeset),
             :ok <- link(invoice.id, transaction_ids) do
          {:ok, Repo.preload(invoice, :transactions)}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:error, _reason} <- result do
      remove_orphan(file)
      result
    end
  end

  # The key is the hash of the PDF: it is only an orphan if no invoice has it,
  # an invoice stored in the meantime owns it.
  defp remove_orphan(file) do
    unless Repo.exists?(from i in Invoice, where: i.file_sha256 == ^file.file_sha256) do
      delete_object(file.file_key)
    end
  end

  defp delete_object(key) do
    case Storage.delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not delete #{key} from storage: #{inspect(reason)}")
    end
  end

  # Matches an invoice to transactions. A transaction that has an invoice is no
  # longer one that needs none.
  defp link(_invoice_id, []), do: :ok

  defp link(invoice_id, transaction_ids) do
    transaction_ids = Enum.uniq(transaction_ids)
    known = Repo.aggregate(from(t in Transaction, where: t.id in ^transaction_ids), :count)

    if known == length(transaction_ids) do
      rows = Enum.map(transaction_ids, &%{invoice_id: invoice_id, transaction_id: &1})
      Repo.insert_all("invoice_transactions", rows, on_conflict: :nothing)

      Repo.update_all(from(t in Transaction, where: t.id in ^transaction_ids),
        set: [no_invoice: false, no_invoice_note: nil]
      )

      :ok
    else
      {:error, :unknown_transaction}
    end
  end

  @doc """
  Updates what is typed in. The PDF stays.
  """
  def update_invoice(%Invoice{} = invoice, attrs) do
    invoice |> Invoice.with_amount_input() |> Invoice.changeset(attrs) |> Repo.update()
  end

  @doc """
  Deletes the invoice and its PDF. The transactions stay.
  """
  def delete_invoice(%Invoice{} = invoice) do
    with {:ok, invoice} <- Repo.delete(invoice) do
      delete_object(invoice.file_key)
      {:ok, invoice}
    end
  end

  @doc """
  Matches the invoice to the transaction. Matching twice is fine.
  """
  def attach(%Invoice{id: invoice_id}, %Transaction{id: transaction_id}) do
    result =
      Repo.transact(fn -> with :ok <- link(invoice_id, [transaction_id]), do: {:ok, :ok} end)

    with {:ok, :ok} <- result, do: :ok
  end

  @doc """
  Takes the invoice off the transaction.
  """
  def detach(%Invoice{id: invoice_id}, %Transaction{id: transaction_id}) do
    Repo.delete_all(
      from "invoice_transactions",
        where: [invoice_id: ^invoice_id, transaction_id: ^transaction_id]
    )

    :ok
  end

  @doc """
  The invoices that could belong to the transaction, best first: the ones of
  exactly the amount, then the ones not matched to anything, then the closest
  in date. Invoices already on the transaction are left out. `search` narrows
  them by issuer name or number.
  """
  def suggest_invoices(%Transaction{} = transaction, search \\ nil) do
    cents = transaction.amount |> Money.cents_from_decimal() |> abs()

    attached =
      from(it in "invoice_transactions",
        where: it.transaction_id == ^transaction.id,
        select: it.invoice_id
      )

    Invoice
    |> where([i], i.id not in subquery(attached))
    |> search(search)
    |> preload(:transactions)
    |> Repo.all()
    |> Enum.sort_by(fn invoice ->
      {
        not (invoice.currency == "EUR" and invoice.amount_cents == cents),
        invoice.transactions != [],
        abs(Date.diff(invoice.date, transaction.date))
      }
    end)
    |> Enum.take(20)
  end

  @doc """
  A temporary URL to download the PDF of the invoice.
  """
  def pdf_url(%Invoice{file_key: key}), do: Storage.presigned_url(key, @pdf_url_ttl)
end
