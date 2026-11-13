defmodule IkeEmails.Bank.Alpha.Details do
  @moduledoc """
  Reads the answers of the bank to the details of the transactions, which
  `priv/bank/statements.js` fetches (`fetchDetails`) one transaction at a time.

  The bank's answer for a transaction holds the one statement that was asked for, and a
  list of details under it:

      {"Statements": [{"StatementDetails": [{"ConversionDetails": "20,00 USD", ...}]}]}

  `parse/1` takes the answers by transaction id, each as the JSON text the bank sent,
  and returns `{:ok, details}`, a map from the transaction id to its
  `IkeEmails.Bank.Alpha.Detail`. Should an answer have several statements or entries,
  their texts are joined (see `IkeEmails.Bank.Alpha.Detail`). A text that is `null` or
  missing is empty, and an answer whose list is empty gives a `Detail` of empty texts.

  An answer that is not JSON, or lacks the `Statements` or their `StatementDetails`, or
  has a text that is not a string, fails all of them with `{:error, :unexpected_response}`:
  the details are not worked from in part.
  """

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Fields

  @spec parse(%{String.t() => String.t()}) ::
          {:ok, %{String.t() => Detail.t()}} | {:error, :unexpected_response}
  def parse(responses) when is_map(responses) do
    responses
    |> Enum.reduce_while({:ok, %{}}, fn {id, body}, {:ok, details} ->
      case detail(body) do
        {:ok, detail} -> {:cont, {:ok, Map.put(details, id, detail)}}
        :error -> {:halt, {:error, :unexpected_response}}
      end
    end)
  end

  def parse(_responses), do: {:error, :unexpected_response}

  defp detail(body) when is_binary(body) do
    with {:ok, response} <- Jason.decode(body),
         {:ok, statements} <- Fields.list(response, "Statements"),
         {:ok, entries} <- Fields.all(statements, &Fields.list(&1, "StatementDetails")) do
      entries |> Enum.concat() |> Detail.from_entries()
    else
      _ -> :error
    end
  end

  defp detail(_body), do: :error
end
