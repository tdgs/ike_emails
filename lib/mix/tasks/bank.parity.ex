defmodule Mix.Tasks.Bank.Parity do
  @shortdoc "Checks that the rows of the Elixir crawler are those of the Gleam one"

  @moduledoc """
  Checks that this app makes the same rows as the crawler written in Gleam, from the files
  of one of its runs:

      mix bank.parity /path/to/bank_crawler/runs/1762246800

  The run directory has the files the crawler saves. The task reads

    * `statements.json` - the statements, as the bank sent them
    * `details.json` - an object from the id of a transaction to the bank's answer for its
      details. The crawler saves each answer as the JSON it is, not as a text, so the task
      writes each one as a text again, which is what `IkeEmails.Bank.Alpha.Details` reads
    * `transactions.csv` - the rows the crawler made from them
    * `crawl.json`, when it is there and is JSON - only its `failed`, a number

  makes the rows again with `IkeEmails.Bank.Alpha.Statements`, `Details` and `Rows`, and
  compares them with the file on all nine fields, row by row, and by the key under which a
  stored transaction is found again, `transaction_id`, `amount` and `description`
  (`IkeEmails.Bank.Parity`). It also says whether the lines add up to the balances of the
  bank (`IkeEmails.Bank.Alpha.Reconcile`), and fails when they do not.

  It prints numbers, and the names of the fields that differ, and never a value, an id or a
  description. When everything is the same it prints `parity 100%`. When anything differs it
  fails, so the exit status of the command is not zero. If so the cleaning of the texts
  (`IkeEmails.Bank.Alpha.Text`) is the first place to look, before anything else is built
  on the rows.

  It needs neither the database nor the bank nor the network, and starts nothing.
  """

  use Mix.Task

  alias IkeEmails.Bank.Alpha.Details
  alias IkeEmails.Bank.Alpha.Reconcile
  alias IkeEmails.Bank.Alpha.Rows
  alias IkeEmails.Bank.Alpha.Statements
  alias IkeEmails.Bank.Csv
  alias IkeEmails.Bank.Parity

  @requirements ["app.config"]

  @impl Mix.Task
  def run([dir]) do
    {:ok, _started} = Application.ensure_all_started(:jason)
    check_decimals!()

    statements = read!(dir, "statements.json")
    details = read!(dir, "details.json")
    csv = read!(dir, "transactions.csv")

    parsed = parse_statements!(statements)
    {rebuilt, rejected, without_details} = rebuild!(parsed, details)
    report = Parity.compare(csv_rows!(csv), rebuilt)
    balances = Reconcile.check(parsed)

    context = %{
      rejected: length(rejected),
      without_details: without_details,
      failed: crawl_failed(dir)
    }

    lines = Parity.lines(report) ++ Parity.context_lines(context) ++ [balances_line(balances)]
    for line <- lines, do: Mix.shell().info(line)

    case problems(report, balances) do
      [] -> Mix.shell().info("parity 100%")
      problems -> Mix.raise(Enum.join(problems, " "))
    end
  end

  def run(_args), do: Mix.raise("Usage: mix bank.parity RUN_DIR")

  # Jason reads a decimal only when it was compiled with Decimal, and a build that was made
  # before Decimal was there raises on the first amount
  defp check_decimals! do
    Jason.decode!("1.5", floats: :decimals)
    :ok
  rescue
    ArgumentError ->
      Mix.raise("Jason was compiled without Decimal. Run: mix deps.compile jason --force")
  end

  defp read!(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, text} -> text
      {:error, reason} -> Mix.raise("Could not read #{name} in the run directory: #{reason}.")
    end
  end

  defp parse_statements!(text) do
    case Statements.parse(text) do
      {:ok, parsed} -> parsed
      {:error, reason} -> Mix.raise("Could not read statements.json: #{reason}.")
    end
  end

  # The rows, the ids of the lines left out for their date, and how many lines have no detail
  defp rebuild!(parsed, details_text) do
    with {:ok, responses} <- details_responses(details_text),
         {:ok, details} <- Details.parse(responses),
         {:ok, rows, rejected} <- Rows.build(parsed.statements, details) do
      {rows, rejected, Parity.without_details(parsed.statements, details)}
    else
      {:error, reason} -> Mix.raise("Could not make the rows again: #{reason}.")
    end
  end

  # A crawl.json that is not there, or cannot be used, says nothing
  defp crawl_failed(dir) do
    case File.read(Path.join(dir, "crawl.json")) do
      {:ok, text} -> Parity.crawl_failed(text)
      {:error, _reason} -> nil
    end
  end

  # An object from the id to the answer, which each is made a text again
  defp details_responses(text) do
    case Jason.decode(text) do
      {:ok, %{} = responses} ->
        {:ok, Map.new(responses, fn {id, response} -> {id, Jason.encode!(response)} end)}

      _other ->
        {:error, :unexpected_details_file}
    end
  end

  defp csv_rows!(text) do
    with {:ok, records} <- Csv.parse(text),
         {:ok, rows} <- Parity.rows_from_csv(records) do
      rows
    else
      {:error, reason} ->
        Mix.raise("transactions.csv is not a file of the crawler: #{inspect(reason)}.")
    end
  end

  defp balances_line(:ok), do: "the lines add up to the balances of the bank"
  defp balances_line({:error, :balances_missing}), do: "the bank gave no balances to add up to"

  defp balances_line({:error, :mismatch}),
    do: "the lines do NOT add up to the balances of the bank"

  # The balances missing is said, not failed: the crawler accepted a run without them
  defp problems(report, balances) do
    parity =
      cond do
        report.csv == 0 and report.rebuilt == 0 ->
          ["There are no rows to compare."]

        Parity.identical?(report) ->
          []

        true ->
          [
            "Parity is not 100%: #{report.identical} of #{max(report.csv, report.rebuilt)} " <>
              "rows are identical."
          ]
      end

    parity ++ if balances == {:error, :mismatch}, do: ["The lines do not add up."], else: []
  end
end
