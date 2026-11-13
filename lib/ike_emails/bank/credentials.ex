defmodule IkeEmails.Bank.Credentials do
  @moduledoc """
  What a login to the bank needs: the user name and the password of myAlpha, and the
  IBAN of the account to read.

  It is a struct, never a bare string or a map, so that none of the three is shown when
  one is inspected or logged (a crash report prints the arguments of a function that
  could not be called). The password is also never put in a function head on its own.
  """

  @derive {Inspect, except: [:username, :password, :iban]}
  @enforce_keys [:username, :password, :iban]
  defstruct [:username, :password, :iban]

  @type t :: %__MODULE__{
          username: String.t(),
          password: String.t(),
          iban: String.t()
        }
end
