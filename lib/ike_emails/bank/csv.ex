defmodule IkeEmails.Bank.Csv do
  @moduledoc """
  Reads a CSV file as RFC 4180 has it, for `mix bank.parity`, which compares the
  `transactions.csv` that the crawler written in Gleam saved with the rows that this app
  makes.

  A record ends with a line feed or with a carriage return and a line feed. A field is
  written in double quotes when it has a comma, a double quote or a line break, and a double
  quote in it is written twice. The file ends with a line break, which does not start
  another record, and may not (the last record is read all the same). A field that is
  empty is `""`.

  A file that was opened and saved again by a spreadsheet or an editor is read as well: a
  UTF-8 byte order mark at the start is not part of the first field, and blank lines at the
  end, however many, are not records. A line break inside a field in quotes is the field's,
  whether it is a line feed or a carriage return and a line feed, and is kept as it is. A
  blank line between two records is a record of one empty field.

  It is strict about quotes, since a file that has them in the wrong place was not written
  by the crawler: a quote inside a field that does not start with one, and anything after
  the closing quote of a field but a comma or the end of the record, is
  `{:error, :malformed}`, and a quote that is never closed is `{:error, :unterminated_quote}`.
  Neither error holds the text.
  """

  @doc """
  The records of `text`, each a list of the fields.

      iex> IkeEmails.Bank.Csv.parse("a,b\\n1,\\"x, \\"\\"y\\"\\"\\"\\n")
      {:ok, [["a", "b"], ["1", ~s(x, "y")]]}
  """
  @spec parse(binary()) :: {:ok, [[String.t()]]} | {:error, :malformed | :unterminated_quote}
  def parse("\uFEFF" <> text), do: start(text, [], [])
  def parse(text) when is_binary(text), do: start(text, [], [])

  # The start of a field. `row` holds the fields of the record so far, the last first. At
  # the start of a record, nothing but line breaks to the end of the text is no record
  defp start(<<?", rest::binary>>, row, rows), do: quoted(rest, "", row, rows)
  defp start(<<>>, [], rows), do: {:ok, Enum.reverse(rows)}

  defp start(rest, [], rows) do
    if only_line_breaks?(rest),
      do: {:ok, Enum.reverse(rows)},
      else: unquoted(rest, "", [], rows)
  end

  defp start(rest, row, rows), do: unquoted(rest, "", row, rows)

  defp only_line_breaks?(<<"\r\n", rest::binary>>), do: only_line_breaks?(rest)
  defp only_line_breaks?(<<"\n", rest::binary>>), do: only_line_breaks?(rest)
  defp only_line_breaks?(<<>>), do: true
  defp only_line_breaks?(_rest), do: false

  defp unquoted(<<",", rest::binary>>, field, row, rows), do: start(rest, [field | row], rows)

  defp unquoted(<<"\r\n", rest::binary>>, field, row, rows),
    do: start(rest, [], record(field, row, rows))

  defp unquoted(<<"\n", rest::binary>>, field, row, rows),
    do: start(rest, [], record(field, row, rows))

  defp unquoted(<<?", _rest::binary>>, _field, _row, _rows), do: {:error, :malformed}
  defp unquoted(<<>>, field, row, rows), do: {:ok, Enum.reverse(record(field, row, rows))}

  defp unquoted(<<char, rest::binary>>, field, row, rows),
    do: unquoted(rest, <<field::binary, char>>, row, rows)

  defp quoted(<<?", ?", rest::binary>>, field, row, rows),
    do: quoted(rest, <<field::binary, ?">>, row, rows)

  defp quoted(<<?", rest::binary>>, field, row, rows), do: closed(rest, field, row, rows)

  defp quoted(<<char, rest::binary>>, field, row, rows),
    do: quoted(rest, <<field::binary, char>>, row, rows)

  defp quoted(<<>>, _field, _row, _rows), do: {:error, :unterminated_quote}

  defp closed(<<",", rest::binary>>, field, row, rows), do: start(rest, [field | row], rows)

  defp closed(<<"\r\n", rest::binary>>, field, row, rows),
    do: start(rest, [], record(field, row, rows))

  defp closed(<<"\n", rest::binary>>, field, row, rows),
    do: start(rest, [], record(field, row, rows))

  defp closed(<<>>, field, row, rows), do: {:ok, Enum.reverse(record(field, row, rows))}
  defp closed(_rest, _field, _row, _rows), do: {:error, :malformed}

  defp record(field, row, rows), do: [Enum.reverse([field | row]) | rows]
end
