defmodule IkeEmails.Bank.Alpha.EStatements do
  @moduledoc """
  Reads the list of the monthly statements of the account, which `priv/bank/statements.js`
  fetches (`listEStatements`) as JSON text, and picks the latest.

  The list has an entry for the month that is not over as well, which the bank has not
  issued: it has no id and no date. Only the issued ones (`"EStatementIssued": true`)
  are kept, as `IkeEmails.Bank.Alpha.EStatement`, in the order given. An issued one needs
  an `EstatementID`, a `DateFrom`, a `DateTo` and an `IssuedDate`, all strings, and the
  two dates must be `yyyy-mm-dd` (four digits, a dash, two digits, a dash, two digits).
  The name of the file the PDF is saved as is made of `DateFrom`, so it must not be able to
  say anything else, such as a path. One entry that is not right fails the whole list.

  Dates are compared as text. In that form the later date is the greater, which is why
  `2025-12` comes after `2025-02`.
  """

  alias IkeEmails.Bank.Alpha.EStatement
  alias IkeEmails.Bank.Alpha.Fields

  @doc """
  The issued statements of the JSON text that `listEStatements` returned, or
  `{:error, :unexpected_response}` when it is not what the module describes.
  """
  @spec parse(String.t()) :: {:ok, [EStatement.t()]} | {:error, :unexpected_response}
  def parse(body) when is_binary(body) do
    with {:ok, response} <- Jason.decode(body),
         {:ok, entries} <- Fields.list(response, "EStatements"),
         {:ok, estatements} <- Fields.all(entries, &estatement/1) do
      {:ok, Enum.reject(estatements, &is_nil/1)}
    else
      _ -> {:error, :unexpected_response}
    end
  end

  def parse(_body), do: {:error, :unexpected_response}

  # `{:ok, nil}` for the one that is not issued
  defp estatement(%{"EStatementIssued" => false}), do: {:ok, nil}

  defp estatement(%{"EStatementIssued" => true} = entry) do
    with {:ok, id} <- Fields.string(entry, "EstatementID"),
         {:ok, date_from} <- date(entry, "DateFrom"),
         {:ok, date_to} <- date(entry, "DateTo"),
         {:ok, issued_date} <- Fields.string(entry, "IssuedDate") do
      {:ok, %EStatement{id: id, date_from: date_from, date_to: date_to, issued_date: issued_date}}
    end
  end

  defp estatement(_entry), do: :error

  defp date(entry, name) do
    with {:ok, date} <- Fields.string(entry, name) do
      if Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/, date), do: {:ok, date}, else: :error
    end
  end

  @doc """
  The statement that ends last, which is that of the latest month. Of two that end the
  same day, the one that comes first. `{:error, :none}` for an empty list.
  """
  @spec latest([EStatement.t()]) :: {:ok, EStatement.t()} | {:error, :none}
  def latest([]), do: {:error, :none}

  def latest([first | rest]) do
    latest =
      Enum.reduce(rest, first, fn next, latest ->
        if next.date_to > latest.date_to, do: next, else: latest
      end)

    {:ok, latest}
  end

  @doc """
  What to save the PDF of `estatement` as, by the month it starts in:
  `estatement-2026-09.pdf`.
  """
  @spec file_name(EStatement.t()) :: String.t()
  def file_name(%EStatement{} = estatement), do: "estatement-" <> month(estatement) <> ".pdf"

  @doc """
  The month, `2026-09`, that `estatement` is the statement of: the first seven characters
  of the day it starts on.
  """
  @spec month(EStatement.t()) :: String.t()
  def month(%EStatement{date_from: date_from}), do: String.slice(date_from, 0, 7)
end
