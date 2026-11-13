defmodule IkeEmails.Bank.Alpha.Statement do
  @moduledoc """
  One line of the statement of the account, as `IkeEmails.Bank.Alpha.Statements.parse/1`
  reads it from the bank. Nothing is cleaned or converted but the amount:

    * `entry_date` and `value_date` - as the bank writes them, `d/M/yyyy`, with or
      without zero padding (`IkeEmails.Bank.Alpha.Rows` makes them ISO dates)
    * `reason` - the description of the transaction
    * `branch` and `transaction_id` - strings. The id is not unique: several lines of
      one statement can share it
    * `amount` - a `Decimal`, with the sign applied: a debit is negative
    * `detail` - the `IkeEmails.Bank.Alpha.Detail` that the statement lists for the
      line itself, or `nil` when the bank lists none, as it does for the most recent
      lines. A detail that is listed but empty is a `Detail` with empty texts, not
      `nil`: it is the line's own, and tells it apart from the other lines of the same id
  """

  alias IkeEmails.Bank.Alpha.Detail

  @enforce_keys [:entry_date, :value_date, :reason, :branch, :transaction_id, :amount]
  defstruct [:entry_date, :value_date, :reason, :branch, :transaction_id, :amount, detail: nil]

  @type t :: %__MODULE__{
          entry_date: String.t(),
          value_date: String.t(),
          reason: String.t(),
          branch: String.t(),
          transaction_id: String.t(),
          amount: Decimal.t(),
          detail: Detail.t() | nil
        }
end
