defmodule IkeEmails.Bank.Alpha.Rows do
  @moduledoc """
  Makes the rows to store from the lines of the statement and the details of the
  transactions: the attributes that `IkeEmails.Banking.create_transaction/2` takes (see
  `IkeEmails.Bank.Crawl.row/0`). `build/2` returns them in the order of the lines, and
  with them the transaction ids of the lines it could not make a row of.

  The detail of a row is the one its own line lists. The bank lists none for the most
  recent lines, and those get the one the details call gave for their transaction id; with
  neither, the row has none. A line's own detail wins even when its texts are empty,
  because several lines can share an id and each has to keep its own details, not take
  those of the call. A row is made of:

    * `date` and `value_date` - ISO dates, `2026-10-05`. The bank writes `d/M/yyyy`, with
      or without a zero in front of the day and the month. A date that is not that, with
      nothing added to it (a time of the day, say), or that is not a day of the calendar,
      makes the line a rejected one: it is left out and the rest go on (see below)
    * `description` - the `reason` of the line, cleaned (see `IkeEmails.Bank.Alpha.Text`)
    * `branch` and `transaction_id` - as the bank sent them, without any cleaning or trim
    * `amount` - a string with the sign and two decimals, `-18.01`, `1157.98`: a debit is
      negative, and there is no separator for thousands. The cents are rounded half away
      from zero (`0.005` is `0.01`, `-0.005` is `-0.01`) and an amount that rounds to
      nothing is `0.00`, never `-0.00`
    * `conversion_details`, `sender_details` and `additional_information` - the texts of
      the detail, cleaned, or `nil` when they are empty

  A rejected line is the error of one row, not of the build. The crawler that this was
  ported from did not check the dates and wrote what it was given, so the API of the app
  refused that one row and the others went on. Here the line is left out, and its
  transaction id is in the list of rejected ids, once for each line and in the order of the
  lines (an id that several lines share is there once for each of them that is rejected). The
  list has the ids, never the dates. Every later build rejects the same line again, so
  whoever calls `build/2` has to show a list that is not empty.

  The cents are worked out from the decimal as the bank wrote it, not from a float. That
  is the one place where an amount differs from that of the crawler in Gleam, which
  rounded the float times a hundred: `1.005` is `1.01` here, and was `1.00` there, since
  the nearest float is a little under it. The bank writes two decimals, for which both
  give the same.
  """

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Statement
  alias IkeEmails.Bank.Alpha.Text
  alias IkeEmails.Bank.Crawl

  @doc """
  The rows of `statements` (`IkeEmails.Bank.Alpha.Statement`), with `details` the
  `IkeEmails.Bank.Alpha.Detail` by transaction id (see `IkeEmails.Bank.Alpha.Details`), and
  the transaction ids of the lines left out for a date that cannot be read (see the module).
  """
  @spec build([Statement.t()], %{String.t() => Detail.t()}) ::
          {:ok, [Crawl.row()], [String.t()]}
  def build(statements, details) when is_list(statements) and is_map(details) do
    {rows, rejected} =
      Enum.reduce(statements, {[], []}, fn statement, {rows, rejected} ->
        case row(statement, details) do
          {:ok, row} -> {[row | rows], rejected}
          {:error, :invalid_date} -> {rows, [statement.transaction_id | rejected]}
        end
      end)

    {:ok, Enum.reverse(rows), Enum.reverse(rejected)}
  end

  defp row(%Statement{} = statement, details) do
    detail = statement.detail || Map.get(details, statement.transaction_id, %Detail{})

    with {:ok, date} <- iso_date(statement.entry_date),
         {:ok, value_date} <- iso_date(statement.value_date) do
      {:ok,
       %{
         date: date,
         value_date: value_date,
         description: Text.clean(statement.reason),
         branch: statement.branch,
         transaction_id: statement.transaction_id,
         amount: format_amount(statement.amount),
         conversion_details: optional(detail.conversion_details),
         sender_details: optional(detail.sender_details),
         additional_information: optional(detail.additional_information)
       }}
    end
  end

  defp optional(text) do
    case Text.clean(text) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  # Only ASCII digits: the day and the month have one or two, the year four
  @date ~r/\A([0-9]{1,2})\/([0-9]{1,2})\/([0-9]{4})\z/

  defp iso_date(date) do
    with [_, day, month, year] <- Regex.run(@date, date),
         {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      {:ok, Date.to_iso8601(date)}
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp format_amount(%Decimal{} = amount) do
    cents = amount |> Decimal.mult(100) |> Decimal.round(0, :half_up) |> Decimal.to_integer()
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    sign <> Integer.to_string(div(cents, 100)) <> "." <> pad_cents(rem(cents, 100))
  end

  defp pad_cents(cents), do: cents |> Integer.to_string() |> String.pad_leading(2, "0")
end
