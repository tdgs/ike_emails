defmodule IkeEmails.Bank.Alpha.EStatement do
  @moduledoc """
  A monthly statement that the bank has issued, as the list of them (the "Copies" tab of
  the account) shows it. `IkeEmails.Bank.Alpha.EStatements` reads the list.

    * `id` - what the bank takes to hand out the PDF of the statement. It is opaque, and
      has characters such as `/`, `+` and `=`, so it is never used in a file name
    * `date_from` and `date_to` - the first and the last day it covers, `2026-09-01` and
      `2026-09-30`. The file is named after them, so they are checked to be nothing but
      digits and dashes in that shape
    * `issued_date` - the day the bank issued it
  """

  @enforce_keys [:id, :date_from, :date_to, :issued_date]
  defstruct [:id, :date_from, :date_to, :issued_date]

  @type t :: %__MODULE__{
          id: String.t(),
          date_from: String.t(),
          date_to: String.t(),
          issued_date: String.t()
        }
end
