defmodule IkeEmails.Chrome.Page do
  @moduledoc """
  A page (a tab) of a browser started by `IkeEmails.Chrome`: the target that was
  opened, and the session that was attached to it, which is what its commands are
  sent through.

  A page that was opened with `context: :isolated` also holds the id of the browser
  context that was made for it, which `IkeEmails.Chrome.close_page/3` disposes of. It is
  `nil` for a page of the default context of the browser.
  """

  @enforce_keys [:target_id, :session_id]
  defstruct [:target_id, :session_id, :browser_context_id]

  @type t :: %__MODULE__{
          target_id: String.t(),
          session_id: String.t(),
          browser_context_id: String.t() | nil
        }
end
