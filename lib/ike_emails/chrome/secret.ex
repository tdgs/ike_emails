defmodule IkeEmails.Chrome.Secret do
  @moduledoc """
  A string that must not be seen when it is inspected, logged or printed by a crash
  report: the password that is typed into a page of the bank.

  A credential given to `IkeEmails.Chrome.call_script/6` is a `Secret`, wherever it
  is in the arguments, and it becomes its string only when the arguments are turned
  into JSON, inside the process of the client (see the `Jason.Encoder` of this
  struct). Until then it is passed around as the struct, and the struct is never
  matched for the string in a function head: a function that cannot be called
  prints its arguments in the crash report.

  `inspect/2` shows `#Secret<redacted>` for it. The string is kept in a function, not
  in the field, so that it is not shown either when the struct is inspected as the map
  it is (`inspect(secret, structs: false)`), or by Erlang, which knows nothing of
  `Inspect`: they print the function, and the function does not show what it holds.
  The field is called `password` for Sentry, which scrubs what has that name.
  """

  @enforce_keys [:password]
  defstruct [:password]

  @opaque t :: %__MODULE__{password: (-> String.t())}

  @doc "Wraps a string."
  @spec new(String.t()) :: t()
  def new(string) when is_binary(string), do: %__MODULE__{password: fn -> string end}

  @doc "The string that was wrapped. Use it where the string is typed, and nowhere else."
  @spec reveal(t()) :: String.t()
  def reveal(%__MODULE__{password: reveal}), do: reveal.()
end
