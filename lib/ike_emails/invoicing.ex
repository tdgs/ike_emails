defmodule IkeEmails.Invoicing do
  @moduledoc """
  The invoices (expenses) and their PDFs, and what they are matched to in the
  bank transactions.
  """

  import Ecto.Query, warn: false

  require Logger

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Banking.Transaction
  alias IkeEmails.Elorus
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Money
  alias IkeEmails.Repo
  alias IkeEmails.Settings
  alias IkeEmails.Storage

  @max_pdf_bytes 20_000_000
  @pdf_url_ttl 300

  def max_pdf_bytes, do: @max_pdf_bytes

  @doc """
  The invoices of the user, newest first, with their transactions. `:search`
  matches the issuer or receiver name, or the invoice number.
  """
  def list_invoices(%Scope{} = scope, opts \\ []) do
    Invoice
    |> where([i], i.user_id == ^Scope.user_id(scope))
    |> search(opts[:search])
    |> order_by([i], desc: i.date, desc: i.id)
    |> preload(:transactions)
    |> Repo.all()
  end

  @doc """
  The invoices of the user dated in the month (a date in it), oldest first.
  """
  def list_invoices_for_month(%Scope{} = scope, %Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Date.end_of_month(month)

    Repo.all(
      from i in Invoice,
        where: i.user_id == ^Scope.user_id(scope),
        where: i.date >= ^first and i.date <= ^last,
        order_by: [asc: i.date, asc: i.id]
    )
  end

  defp search(query, term) when is_binary(term) do
    case String.trim(term) do
      "" ->
        query

      term ->
        pattern = "%" <> String.replace(term, ~r/[\\%_]/, "\\\\\\0") <> "%"

        where(
          query,
          [i],
          ilike(i.issuer_name, ^pattern) or ilike(i.receiver_name, ^pattern) or
            ilike(i.number, ^pattern)
        )
    end
  end

  defp search(query, _term), do: query

  @doc """
  Gets an invoice of the user with its transactions. Raises when there is none,
  which is also the case for the invoice of another user.
  """
  def get_invoice!(%Scope{} = scope, id) do
    Invoice
    |> Repo.get_by!(id: id, user_id: Scope.user_id(scope))
    |> Repo.preload(:transactions)
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
  Stores the PDF and the invoice of the user, and links the invoice to the given
  `:transaction_ids`, if any. They must be transactions of the user.

  Errors: a changeset, `:not_a_pdf`, `:too_large`, `{:duplicate, invoice}` when
  the same PDF was uploaded before, `:unknown_transaction` and
  `{:storage, reason}`.
  """
  def create_invoice(%Scope{} = scope, attrs, pdf, file_name, opts \\ []) when is_binary(pdf) do
    transaction_ids = Keyword.get(opts, :transaction_ids, [])
    file = file_facts(scope, pdf, file_name)

    changeset =
      %Invoice{user_id: Scope.user_id(scope)}
      |> Invoice.create_changeset(attrs, file)
      |> put_elorus_id(opts[:elorus_id])

    with :ok <- check_pdf(pdf),
         :ok <- check_new(scope, file.file_sha256),
         {:ok, changeset} <- apply_valid(changeset),
         :ok <- store(file, pdf) do
      insert_invoice(scope, changeset, transaction_ids, file)
    end
  end

  # The key has the user in it: the same PDF of two users is two objects, so that
  # deleting the invoice of one does not take the PDF of the other
  defp file_facts(scope, pdf, file_name) do
    sha256 = :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)

    %{
      file_key: "invoices/#{Scope.user_id(scope)}/#{sha256}.pdf",
      file_name:
        file_name |> Path.basename() |> String.codepoints() |> Enum.take(255) |> Enum.join(),
      file_size: byte_size(pdf),
      file_sha256: sha256
    }
  end

  defp check_pdf(pdf) when byte_size(pdf) > @max_pdf_bytes, do: {:error, :too_large}
  defp check_pdf("%PDF-" <> _), do: :ok
  defp check_pdf(_), do: {:error, :not_a_pdf}

  defp check_new(scope, sha256) do
    case Repo.get_by(Invoice, user_id: Scope.user_id(scope), file_sha256: sha256) do
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

  defp insert_invoice(scope, changeset, transaction_ids, file) do
    result =
      Repo.transact(fn ->
        with {:ok, invoice} <- Repo.insert(changeset),
             :ok <- link(scope, invoice.id, transaction_ids) do
          {:ok, Repo.preload(invoice, :transactions)}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:error, _reason} <- result do
      remove_orphan(scope, file)
      result
    end
  end

  # The key is the user and the hash of the PDF: it is only an orphan if no
  # invoice has it, an invoice stored in the meantime owns it.
  defp remove_orphan(scope, file) do
    unless Repo.exists?(
             from i in Invoice,
               where: i.user_id == ^Scope.user_id(scope) and i.file_sha256 == ^file.file_sha256
           ) do
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

  # Matches an invoice to transactions of the same user. A transaction that has an
  # invoice is no longer one that needs none.
  defp link(_scope, _invoice_id, []), do: :ok

  defp link(scope, invoice_id, transaction_ids) do
    transaction_ids = Enum.uniq(transaction_ids)
    transactions = from(t in Transaction, where: t.user_id == ^Scope.user_id(scope))
    known = Repo.aggregate(where(transactions, [t], t.id in ^transaction_ids), :count)

    if known == length(transaction_ids) do
      rows = Enum.map(transaction_ids, &%{invoice_id: invoice_id, transaction_id: &1})
      Repo.insert_all("invoice_transactions", rows, on_conflict: :nothing)

      Repo.update_all(where(transactions, [t], t.id in ^transaction_ids),
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
  def update_invoice(%Scope{} = scope, %Invoice{} = invoice, attrs) do
    scope
    |> Scope.authorize!(invoice)
    |> Invoice.with_amount_input()
    |> Invoice.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes the invoice and its PDF. The transactions stay.
  """
  def delete_invoice(%Scope{} = scope, %Invoice{} = invoice) do
    with {:ok, invoice} <- scope |> Scope.authorize!(invoice) |> Repo.delete() do
      delete_object(invoice.file_key)
      {:ok, invoice}
    end
  end

  @doc """
  Matches the invoice to the transaction. Matching twice is fine.
  """
  def attach(%Scope{} = scope, %Invoice{id: invoice_id} = invoice, %Transaction{} = transaction) do
    Scope.authorize!(scope, invoice)
    Scope.authorize!(scope, transaction)

    result =
      Repo.transact(fn ->
        with :ok <- link(scope, invoice_id, [transaction.id]), do: {:ok, :ok}
      end)

    with {:ok, :ok} <- result, do: :ok
  end

  @doc """
  Takes the invoice off the transaction.
  """
  def detach(%Scope{} = scope, %Invoice{id: invoice_id} = invoice, %Transaction{} = transaction) do
    Scope.authorize!(scope, invoice)
    Scope.authorize!(scope, transaction)

    Repo.delete_all(
      from "invoice_transactions",
        where: [invoice_id: ^invoice_id, transaction_id: ^transaction.id]
    )

    :ok
  end

  @doc """
  The invoices of the user that could belong to the transaction, best first: the
  ones of exactly the amount, then the ones not matched to anything, then the
  closest in date. Invoices already on the transaction are left out. `search`
  narrows them by issuer name or number.
  """
  def suggest_invoices(%Scope{} = scope, %Transaction{} = transaction, search \\ nil) do
    Scope.authorize!(scope, transaction)
    cents = transaction.amount |> Money.cents_from_decimal() |> abs()

    attached =
      from(it in "invoice_transactions",
        where: it.transaction_id == ^transaction.id,
        select: it.invoice_id
      )

    Invoice
    |> where([i], i.user_id == ^Scope.user_id(scope))
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

  defp put_elorus_id(changeset, nil), do: changeset
  defp put_elorus_id(changeset, elorus_id), do: Invoice.put_elorus_id(changeset, elorus_id)

  ## Invoices issued in Elorus

  @doc """
  The invoices Elorus has for a month (by their issue date, drafts and void
  ones left out), the ones that could be the invoice of the transaction first.
  The others keep the order Elorus gave, newest first.

  The search is made with the Elorus credentials the user unlocked (see
  `IkeEmails.Elorus.Connection`). Errors are those of
  `IkeEmails.Elorus.list_all_invoices/3`, and `:locked` when they are not unlocked.
  """
  def search_elorus(%Scope{} = scope, %Transaction{} = transaction, %Date{} = month) do
    Scope.authorize!(scope, transaction)

    params = [
      period_from: Date.beginning_of_month(month),
      period_to: Date.end_of_month(month),
      draft: false,
      is_void: false
    ]

    with {:ok, invoices} <- Elorus.Connection.list_all_invoices(scope, params) do
      {matching, others} = Enum.split_with(invoices, &elorus_match?(&1, transaction))
      {:ok, matching ++ others}
    end
  end

  @doc """
  Whether an Elorus invoice is for the amount of the transaction, in the currency
  it was charged in (see `new_invoice_for/1`). The invoice can be for its total or
  for what is payable, which is less when a tax is withheld.
  """
  def elorus_match?(%Elorus.Invoice{} = invoice, %Transaction{} = transaction) do
    %Invoice{amount_input: input, currency: currency} = new_invoice_for(transaction)

    with true <- invoice.currency_code == currency,
         {:ok, cents} <- Money.parse_cents(input) do
      Enum.any?([invoice.total, invoice.payable], &(decimal_cents(&1) == cents))
    else
      _ -> false
    end
  end

  defp decimal_cents(%Decimal{} = amount), do: Money.cents_from_decimal(amount)
  defp decimal_cents(_amount), do: nil

  @doc """
  Which of the Elorus invoices (by id) the user imported already.
  """
  def imported_elorus_ids(%Scope{}, []), do: MapSet.new()

  def imported_elorus_ids(%Scope{} = scope, elorus_ids) do
    Repo.all(
      from i in Invoice,
        where: i.user_id == ^Scope.user_id(scope) and i.elorus_id in ^elorus_ids,
        select: i.elorus_id
    )
    |> MapSet.new()
  end

  @doc """
  Makes the Elorus invoice the invoice of the transaction: downloads its PDF,
  stores it with the invoice, and links the transaction, as an upload would.

  An invoice that was imported before is only attached, which needs no
  credentials, and so is the invoice that already holds the same PDF (which is
  taken as the import of the Elorus invoice, if it was not one). The issuer is the
  business of the user (see `IkeEmails.Settings.business/1`), the receiver the
  client of the Elorus invoice. The PDF is downloaded with the credentials the
  user unlocked (see `IkeEmails.Elorus.Connection`).

  Returns `{:ok, invoice}`, or `{:error, reason}`: `:business_not_configured`,
  `:locked`, an `IkeEmails.Elorus` error, or any error of `create_invoice/5`.
  """
  def import_elorus_invoice(
        %Scope{} = scope,
        %Elorus.Invoice{} = elorus_invoice,
        %Transaction{} = transaction
      ) do
    Scope.authorize!(scope, transaction)

    case Repo.get_by(Invoice, user_id: Scope.user_id(scope), elorus_id: elorus_invoice.id) do
      %Invoice{} = invoice -> attach_stored(scope, invoice, transaction)
      nil -> download_and_create(scope, elorus_invoice, transaction)
    end
  end

  defp download_and_create(scope, elorus_invoice, transaction) do
    with {:ok, business} <- business(scope),
         {:ok, attrs} <- elorus_attrs(elorus_invoice, business),
         :ok <- check_attrs(attrs),
         {:ok, pdf} <- Elorus.Connection.invoice_pdf(scope, elorus_invoice.id) do
      scope
      |> create_invoice(attrs, pdf, elorus_file_name(elorus_invoice),
        transaction_ids: [transaction.id],
        elorus_id: elorus_invoice.id
      )
      |> after_import(scope, elorus_invoice, transaction)
    end
  end

  # The same PDF is stored already: that invoice is the one
  defp after_import({:error, {:duplicate, invoice}}, scope, elorus_invoice, transaction) do
    invoice |> claim_elorus_id(elorus_invoice.id) |> then(&attach_stored(scope, &1, transaction))
  end

  # Stored by another import between the checks and the insert: one of the two
  # unique indexes refused this one, depending on which comes first
  defp after_import(
         {:error, %Ecto.Changeset{} = changeset} = error,
         scope,
         elorus_invoice,
         transaction
       ) do
    case stored_in_the_meantime(scope, changeset, elorus_invoice) do
      %Invoice{} = invoice ->
        invoice
        |> claim_elorus_id(elorus_invoice.id)
        |> then(&attach_stored(scope, &1, transaction))

      nil ->
        error
    end
  end

  defp after_import(result, _scope, _elorus_invoice, _transaction), do: result

  defp stored_in_the_meantime(scope, changeset, elorus_invoice) do
    user_id = Scope.user_id(scope)

    cond do
      Keyword.has_key?(changeset.errors, :elorus_id) ->
        Repo.get_by(Invoice, user_id: user_id, elorus_id: elorus_invoice.id)

      Keyword.has_key?(changeset.errors, :file_sha256) ->
        Repo.get_by(Invoice,
          user_id: user_id,
          file_sha256: Ecto.Changeset.get_field(changeset, :file_sha256)
        )

      true ->
        nil
    end
  end

  # An invoice that was uploaded by hand becomes the import of the Elorus invoice,
  # so that it is not downloaded again. One that belongs to another is left alone.
  defp claim_elorus_id(%Invoice{elorus_id: nil} = invoice, elorus_id) do
    case invoice
         |> Ecto.Changeset.change()
         |> Invoice.put_elorus_id(elorus_id)
         |> Repo.update() do
      {:ok, claimed} -> claimed
      {:error, _changeset} -> invoice
    end
  end

  defp claim_elorus_id(invoice, _elorus_id), do: invoice

  defp attach_stored(scope, invoice, transaction) do
    with :ok <- attach(scope, invoice, transaction), do: {:ok, get_invoice!(scope, invoice.id)}
  end

  defp business(scope) do
    case Settings.business(scope) do
      nil -> {:error, :business_not_configured}
      business -> {:ok, business}
    end
  end

  defp elorus_attrs(
         %Elorus.Invoice{total: %Decimal{} = total, date: %Date{} = date} = e,
         business
       ) do
    {:ok,
     %{
       "amount_input" => total |> Money.cents_from_decimal() |> Money.format_input(),
       "currency" => e.currency_code,
       "date" => Date.to_iso8601(date),
       "issuer_name" => business.name,
       "issuer_vat" => business.vat,
       "receiver_name" => e.client_name,
       "receiver_vat" => e.client_vat_number,
       "number" => elorus_number(e),
       "notes" => "Imported from Elorus"
     }}
  end

  defp elorus_attrs(_elorus_invoice, _business), do: {:error, :invalid_elorus_invoice}

  # Do not download a PDF for an invoice that cannot be stored
  defp check_attrs(attrs) do
    changeset = change_invoice(%Invoice{}, attrs)
    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  # The number as it is printed: the sequence "A-" and the number "1" make "A-1"
  defp elorus_number(%Elorus.Invoice{} = invoice) do
    case Enum.join(Enum.reject([invoice.sequence_flat, invoice.number], &is_nil/1)) do
      "" -> nil
      number -> number
    end
  end

  defp elorus_file_name(%Elorus.Invoice{} = invoice) do
    name = elorus_number(invoice) || invoice.id
    "elorus-" <> String.replace(name, ~r/[^A-Za-z0-9._-]/u, "_") <> ".pdf"
  end

  @doc """
  A temporary URL to download the PDF of the invoice.
  """
  def pdf_url(%Invoice{file_key: key}), do: Storage.presigned_url(key, @pdf_url_ttl)
end
