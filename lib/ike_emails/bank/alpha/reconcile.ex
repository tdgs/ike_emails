defmodule IkeEmails.Bank.Alpha.Reconcile do
  @moduledoc """
  Checks the lines of a statement against the balances the bank gives with them: the
  amounts of all the lines, with their signs, must add up to how much the balance moved
  between the start of the range and its end.

  A crawl that reads the statements in pieces, or that misses a line, would otherwise
  store a statement with a hole in it and say nothing. `priv/bank/statements.js` makes
  this check in the page, with floats rounded to cents. This is the second one, with exact
  decimals, on what was actually parsed, since a crawl must not store what does not add
  up.

  `check/1` takes what `IkeEmails.Bank.Alpha.Statements.parse/1` returned and gives

    * `:ok` - they add up. No lines at all, between two equal balances, add up
    * `{:error, :mismatch}` - they do not
    * `{:error, :balances_missing}` - the bank sent no balance, or no sign for one. The
      script in the page skips its check in that case, but this one refuses: a check that
      can be skipped by leaving out what it checks is no check

  A balance is positive for the sign `:credit` and negative for `:debit`.
  """

  alias IkeEmails.Bank.Alpha.Statements

  @spec check(Statements.parsed()) :: :ok | {:error, :balances_missing | :mismatch}
  def check(%{statements: statements} = parsed) do
    with {:ok, opening, closing} <- balances(parsed) do
      added = Enum.reduce(statements, Decimal.new(0), &Decimal.add(&2, &1.amount))

      if Decimal.equal?(added, Decimal.sub(closing, opening)) do
        :ok
      else
        {:error, :mismatch}
      end
    end
  end

  defp balances(%{
         previous_balance: previous,
         previous_balance_sign: previous_sign,
         new_balance: new,
         new_balance_sign: new_sign
       })
       when not is_nil(previous) and not is_nil(previous_sign) and not is_nil(new) and
              not is_nil(new_sign) do
    {:ok, signed(previous, previous_sign), signed(new, new_sign)}
  end

  defp balances(_parsed), do: {:error, :balances_missing}

  defp signed(balance, :credit), do: balance
  defp signed(balance, :debit), do: Decimal.negate(balance)
end
