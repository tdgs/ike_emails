defmodule IkeEmails.Bank.Parity do
  @moduledoc """
  The comparison behind `mix bank.parity`: whether the rows that this app makes from a run
  of the crawler written in Gleam (`statements.json` and `details.json`) are the rows that
  the crawler wrote to `transactions.csv`.

  They have to be the same character for character. A stored transaction is found again by
  `transaction_id`, `amount` and `description`, so a description that is cleaned in a
  different way would store every transaction a second time.

  The rows are compared on the nine fields of the file: `date`, `value_date`, `description`,
  `branch`, `transaction_id`, `amount`, `conversion_details`, `sender_details` and
  `additional_information`. A field that is empty in the file is `nil` in a row that this app
  makes, and the comparison takes them for the same.

  `compare/2` pairs the rows of the file with the rebuilt ones in two ways:

    * in order, the first with the first, and so on. The rows that are the same on all nine
      fields are counted, and for the others, which fields are not the same
    * by the key, `transaction_id`, `amount` and `description`. The rows that one side has
      and the other has not are counted, and so are the fields that differ in those that
      the key pairs (the one that comes first with the one that comes first, for a key that
      is in several rows)

  The report holds numbers and the names of fields. It holds no value from a row, no id and
  no description, because the person who reads it has the files and the report goes to
  a terminal. `lines/1` writes it.

  Next to the report go three numbers that tell why the two sides can differ, which
  `context_lines/1` writes: how many lines of the statements this app leaves out for a date
  it cannot read (`IkeEmails.Bank.Alpha.Rows`) while the crawler in Gleam wrote them,
  how many have no detail of their own and none in `details.json` (a crawl of this app does
  not store those, see `IkeEmails.Bank.Sync`; `without_details/2` counts them), and how many
  details the crawl said it failed (`crawl_failed/1`, from `crawl.json`).
  """

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Statement

  @fields [
    :date,
    :value_date,
    :description,
    :branch,
    :transaction_id,
    :amount,
    :conversion_details,
    :sender_details,
    :additional_information
  ]
  @key [:transaction_id, :amount, :description]

  @type row :: %{optional(atom()) => String.t() | nil}
  @type report :: %{
          csv: non_neg_integer(),
          rebuilt: non_neg_integer(),
          identical: non_neg_integer(),
          csv_only: non_neg_integer(),
          rebuilt_only: non_neg_integer(),
          in_order: [{atom(), pos_integer()}],
          by_key: [{atom(), pos_integer()}]
        }

  @doc "The names of the columns of the file, in order."
  @spec columns() :: [String.t()]
  def columns, do: Enum.map(@fields, &Atom.to_string/1)

  @doc """
  The rows of the records of `transactions.csv`, as maps from the name of the field, an
  atom, to its text. The first record is the header. Errors, with no text from the file:

    * `{:error, :empty}` - there is no record
    * `{:error, :header}` - the first record is not the header of the crawler
    * `{:error, {:columns, n}}` - the record `n`, counted from 1 after the header, does not
      have nine fields
  """
  @spec rows_from_csv([[String.t()]]) ::
          {:ok, [row()]} | {:error, :empty | :header | {:columns, pos_integer()}}
  def rows_from_csv([]), do: {:error, :empty}

  def rows_from_csv([header | records]) do
    if header == columns() do
      records
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {record, number}, {:ok, rows} ->
        if length(record) == length(@fields),
          do: {:cont, {:ok, [Map.new(Enum.zip(@fields, record)) | rows]}},
          else: {:halt, {:error, {:columns, number}}}
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :header}
    end
  end

  @doc """
  Compares the rows of the file with the rebuilt rows, see the module. Returns the report:
  the number of rows of each, `identical` (in order), `csv_only` and `rebuilt_only` (by
  the key), and `in_order` and `by_key`, how many rows differ in each field, as
  `{field, count}` in the order of the columns, and only the fields that differ.
  """
  @spec compare([row()], [row()]) :: report()
  def compare(csv_rows, rebuilt_rows) do
    csv = Enum.map(csv_rows, &normalize/1)
    rebuilt = Enum.map(rebuilt_rows, &normalize/1)

    ordered = Enum.zip(csv, rebuilt)
    keyed = by_key(csv, rebuilt)

    %{
      csv: length(csv),
      rebuilt: length(rebuilt),
      identical: Enum.count(ordered, fn {a, b} -> a == b end),
      csv_only: keyed |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
      rebuilt_only: keyed |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      in_order: tally(ordered),
      by_key: tally(Enum.flat_map(keyed, &elem(&1, 2)))
    }
  end

  defp normalize(row), do: Map.new(@fields, fn field -> {field, Map.get(row, field) || ""} end)

  # For every key, how many rows only the file has, how many only the rebuilt rows have,
  # and the pairs
  defp by_key(csv, rebuilt) do
    in_csv = Enum.group_by(csv, &key/1)
    in_rebuilt = Enum.group_by(rebuilt, &key/1)

    for key <- Enum.uniq(Map.keys(in_csv) ++ Map.keys(in_rebuilt)) do
      a = Map.get(in_csv, key, [])
      b = Map.get(in_rebuilt, key, [])
      pairs = Enum.zip(a, b)

      {length(a) - length(pairs), length(b) - length(pairs), pairs}
    end
  end

  defp key(row), do: Enum.map(@key, &Map.fetch!(row, &1))

  defp tally(pairs) do
    counts =
      Enum.frequencies(
        for {a, b} <- pairs,
            field <- @fields,
            Map.fetch!(a, field) != Map.fetch!(b, field),
            do: field
      )

    for field <- @fields, count = Map.get(counts, field), do: {field, count}
  end

  @doc """
  Whether the report shows no difference: the same number of rows, all the same in order,
  none that only one side has, and no field that differs. A comparison of no rows is not
  one: it proves nothing.
  """
  @spec identical?(report()) :: boolean()
  def identical?(%{csv: 0, rebuilt: 0}), do: false

  def identical?(report) do
    report.csv == report.rebuilt and report.identical == report.csv and
      report.csv_only == 0 and report.rebuilt_only == 0 and
      report.in_order == [] and report.by_key == []
  end

  @doc """
  How many of `statements` (`IkeEmails.Bank.Alpha.Statement`) list no detail of their own and
  have none in `details`, the `IkeEmails.Bank.Alpha.Detail` by transaction id: the lines
  that a crawl of this app leaves out as `skipped`. Several lines can share an id, and each
  is counted.
  """
  @spec without_details([Statement.t()], %{String.t() => Detail.t()}) :: non_neg_integer()
  def without_details(statements, details) when is_list(statements) and is_map(details) do
    Enum.count(statements, &(is_nil(&1.detail) and not Map.has_key?(details, &1.transaction_id)))
  end

  @doc """
  The `failed` of the text of a `crawl.json`, how many details the crawl failed to get, or
  `nil` when the text is not JSON, is not an object, or its `failed` is not a count. Nothing
  else of the file is read.
  """
  @spec crawl_failed(binary()) :: non_neg_integer() | nil
  def crawl_failed(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"failed" => failed}} when is_integer(failed) and failed >= 0 -> failed
      _other -> nil
    end
  end

  @doc "The report as lines of text for a terminal."
  @spec lines(report()) :: [String.t()]
  def lines(report) do
    [
      "rows in transactions.csv: #{report.csv}",
      "rows rebuilt from statements.json and details.json: #{report.rebuilt}",
      "rows identical on all nine fields, paired in order: #{report.identical}",
      "rows only in transactions.csv, by transaction_id, amount and description: " <>
        "#{report.csv_only}",
      "rows only in the rebuilt rows, by transaction_id, amount and description: " <>
        "#{report.rebuilt_only}"
    ] ++
      field_lines("fields that differ, rows paired in order:", report.in_order) ++
      field_lines(
        "fields that differ, rows paired by transaction_id, amount and description:",
        report.by_key
      )
  end

  @doc """
  The lines of text with the numbers that go with the report, see the module. `context` has
  `:rejected`, how many lines the rebuilt rows leave out for a date, `:without_details`,
  and `:failed`, which is `nil` when there is no `crawl.json` to say, and then has no line.
  """
  @spec context_lines(%{
          rejected: non_neg_integer(),
          without_details: non_neg_integer(),
          failed: non_neg_integer() | nil
        }) :: [String.t()]
  def context_lines(%{rejected: rejected, without_details: without_details, failed: failed}) do
    [
      "lines left out of the rebuilt rows for a date that cannot be read: #{rejected}",
      "lines with no detail of their own and none in details.json: #{without_details}"
    ] ++
      if(failed, do: ["details that failed in the crawl, from crawl.json: #{failed}"], else: [])
  end

  defp field_lines(_title, []), do: []

  defp field_lines(title, fields) do
    [title | for({field, count} <- fields, do: "  #{field}: #{count}")]
  end
end
