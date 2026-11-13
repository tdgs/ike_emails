defmodule IkeEmails.Bank.Alpha.Statements do
  @moduledoc """
  Reads the statements of the account, which `priv/bank/statements.js` fetches from the
  bank (`fetch`) and returns as JSON text.

  `parse/1` returns `{:ok, parsed}`, where `parsed` is a map with

    * `statements` - the `IkeEmails.Bank.Alpha.Statement` lines, in the order the bank
      gave them (newest first)
    * `previous_balance` and `previous_balance_sign` - the balance before the first line
    * `new_balance` and `new_balance_sign` - the balance after the last line

  A balance is a `Decimal`, as the bank sends it, and a sign, `:debit` or `:credit`;
  each is `nil` when the bank sent none. They are not used to make rows:
  `IkeEmails.Bank.Alpha.Reconcile` checks the lines against them.

  The reason is `{:error, :unexpected_response}` when the body is not JSON, has no list
  of `Statements`, or a line of it lacks a field, has one of another type, or has an
  `AmountSign` that is neither the Greek capital Chi or the Latin `X` (a debit) nor the
  Greek capital Pi or the Latin `P` (a credit). One line that cannot be read fails the
  whole body: a crawl never works from some of the lines.

  Amounts are read as they are written, with `Jason.decode(floats: :decimals)`, and are
  integers or decimals in the JSON. They are never floats, so adding them up is exact.
  The `StatementDetails` of a line, a list of entries, are its own detail whenever the
  list is not empty, whatever the texts in them are. When it is empty, `null` or missing,
  the line has none (`detail: nil`).
  """

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Fields
  alias IkeEmails.Bank.Alpha.Statement

  @type parsed :: %{
          statements: [Statement.t()],
          previous_balance: Decimal.t() | nil,
          previous_balance_sign: Fields.sign() | nil,
          new_balance: Decimal.t() | nil,
          new_balance_sign: Fields.sign() | nil
        }

  @doc """
  Reads the JSON text that `fetch` returned. See the module for what comes back.
  """
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, :unexpected_response}
  def parse(body) when is_binary(body) do
    with {:ok, response} <- Jason.decode(body, floats: :decimals),
         {:ok, raw_statements} <- Fields.list(response, "Statements"),
         {:ok, statements} <- Fields.all(raw_statements, &statement/1),
         {:ok, previous_balance} <- Fields.optional_number(response, "PreviousGrossBalance"),
         {:ok, previous_sign} <- Fields.optional_sign(response, "PreviousGrossBalanceSign"),
         {:ok, new_balance} <- Fields.optional_number(response, "NewGrossBalance"),
         {:ok, new_sign} <- Fields.optional_sign(response, "NewGrossBalanceSign") do
      {:ok,
       %{
         statements: statements,
         previous_balance: previous_balance,
         previous_balance_sign: previous_sign,
         new_balance: new_balance,
         new_balance_sign: new_sign
       }}
    else
      _ -> {:error, :unexpected_response}
    end
  end

  def parse(_body), do: {:error, :unexpected_response}

  defp statement(object) do
    with {:ok, entry_date} <- Fields.string(object, "EntryDate"),
         {:ok, value_date} <- Fields.string(object, "Valeur"),
         {:ok, reason} <- Fields.string(object, "Reason"),
         {:ok, branch} <- Fields.string(object, "Branch"),
         {:ok, transaction_id} <- Fields.string(object, "TransactionUN"),
         {:ok, amount} <- Fields.number(object, "Amount"),
         {:ok, sign} <- Fields.sign(object, "AmountSign"),
         {:ok, detail} <- own_detail(object) do
      {:ok,
       %Statement{
         entry_date: entry_date,
         value_date: value_date,
         reason: reason,
         branch: branch,
         transaction_id: transaction_id,
         amount: signed(amount, sign),
         detail: detail
       }}
    end
  end

  defp signed(amount, :credit), do: amount
  defp signed(amount, :debit), do: Decimal.negate(amount)

  defp own_detail(object) do
    case Map.get(object, "StatementDetails") do
      nil -> {:ok, nil}
      [] -> {:ok, nil}
      entries when is_list(entries) -> Detail.from_entries(entries)
      _ -> :error
    end
  end
end
