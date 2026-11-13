defmodule IkeEmails.Reports do
  @moduledoc """
  The report of a month: a zip of its bank statement and its invoices, the ones
  received (expenses) and the ones issued (incomes) apart.
  """

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Invoicing
  alias IkeEmails.Statements
  alias IkeEmails.Storage

  @name_length 80

  @doc """
  The zip of the month (a date in it), as `{:ok, file_name, zip}`. The statement
  is at the top, the invoices in `incoming/` and `outgoing/`; an invoice is
  outgoing when it has a receiver, which is how an invoice you issued is
  recorded.

  Errors: `:no_statement`, when the month has none, and `{:storage, key, reason}`
  for a PDF that could not be read.
  """
  def month_zip(%Scope{} = scope, %Date{} = month) do
    case Statements.get_statement(scope, month) do
      nil -> {:error, :no_statement}
      statement -> build(scope, statement, month)
    end
  end

  defp build(scope, statement, month) do
    label = Calendar.strftime(month, "%Y-%m")

    {outgoing, incoming} =
      scope |> Invoicing.list_invoices_for_month(month) |> Enum.split_with(& &1.receiver_name)

    files =
      [{"statement-#{label}.pdf", statement.file_key}] ++
        invoice_files("incoming", incoming, & &1.issuer_name) ++
        invoice_files("outgoing", outgoing, & &1.receiver_name)

    with {:ok, entries} <- fetch_all(files) do
      # shortcut: the whole zip is built in memory (a PDF is at most 20 MB), stream
      # it if a month ever gets big
      {:ok, {_name, zip}} = :zip.create(~c"report.zip", entries, [:memory])
      {:ok, "report-#{label}.zip", zip}
    end
  end

  defp invoice_files(folder, invoices, party) do
    for invoice <- invoices do
      name = "#{invoice.date}-#{clean(party.(invoice))}-#{invoice.id}.pdf"
      {"#{folder}/#{name}", invoice.file_key}
    end
  end

  # Whoever issued the invoice types the name: it must not make a folder or a
  # path of its own in the zip
  defp clean(name) do
    name
    |> String.replace(~r/[\/\\:*?"<>|[:cntrl:]]+/u, "_")
    |> String.slice(0, @name_length)
    |> String.trim()
  end

  defp fetch_all(files) do
    files
    |> Task.async_stream(
      fn {path, key} -> {path, key, Storage.fetch(key)} end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {path, _key, {:ok, body}}}, {:ok, entries} ->
        {:cont, {:ok, [{String.to_charlist(path), body} | entries]}}

      {:ok, {_path, key, {:error, reason}}}, _acc ->
        {:halt, {:error, {:storage, key, reason}}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end
end
