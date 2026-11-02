defmodule IkeEmails.Elorus.Credentials do
  @moduledoc """
  What a call to Elorus needs: the API key of an Elorus user, and the id of the
  organization to work on, which `:demo` makes a demo one.

  It is a struct, never a bare string or a keyword list, so that the API key is
  not shown when one is inspected or logged. The field is called `api_token` for
  Sentry, which scrubs what has that name.
  """

  @derive {Inspect, except: [:api_token]}
  defstruct [:api_token, :organization_id, demo: false]

  @type t :: %__MODULE__{
          api_token: String.t() | nil,
          organization_id: String.t() | nil,
          demo: boolean()
        }
end
