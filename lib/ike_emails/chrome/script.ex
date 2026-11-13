defmodule IkeEmails.Chrome.Script do
  @moduledoc """
  The JavaScript that calls a function of a script with arguments, for
  `IkeEmails.Chrome.call_script/6`.

  The scripts of the crawler (`priv/bank/login.js`, `priv/bank/statements.js`) are one
  expression that evaluates to an object of functions. Calling one is
  `(<script>\\n).<function>(<arguments as JSON>)`, with a line break before the
  parenthesis so that a comment on the last line of the script cannot swallow it.

  The result is iodata, and the arguments are encoded last, by `Jason`, so that a
  `IkeEmails.Chrome.Secret` among them becomes its string only here. This is called
  in the process of the client, at the moment the command is sent, so the string is
  not in the process of the caller, in a message or in a log.
  """

  @identifier ~r/\A[A-Za-z_$][A-Za-z0-9_$]*\z/

  @doc """
  The expression, or `{:error, :invalid_function}` when `function` is not the name of
  a function, or `{:error, :invalid_arguments}` when the arguments are not JSON. Neither
  reason holds the arguments: the exception of `Jason` names the value it could not
  encode, and it is not passed on.

      iex> {:ok, expression} = IkeEmails.Chrome.Script.call("({f: (x) => x})", "f", %{a: 1})
      iex> IO.iodata_to_binary(expression)
      "(({f: (x) => x})\\n).f({\\"a\\":1})"
  """
  @spec call(iodata(), String.t(), term()) ::
          {:ok, iodata()} | {:error, :invalid_function | :invalid_arguments}
  def call(source, function, args) do
    if is_binary(function) and Regex.match?(@identifier, function) do
      {:ok, ["(", source, "\n).", function, "(", Jason.encode_to_iodata!(args), ")"]}
    else
      {:error, :invalid_function}
    end
  rescue
    _exception -> {:error, :invalid_arguments}
  end
end
