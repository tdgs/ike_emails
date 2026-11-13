defmodule IkeEmails.Chrome.Reply do
  @moduledoc """
  What `IkeEmails.Chrome` makes of the replies of Chrome before a caller sees them.

  A reply to a command is `{"id": n, "result": {...}}` or `{"id": n, "error": {...}}`.
  Two things in them are kept from the caller, because they can hold what the page was
  given or what it showed:

    * the text of an exception. Chrome describes a script that threw with the message
      of the error and its stack, and a message often repeats what the script was given,
      which can be a password. Only the line and the column are kept
    * the text of a protocol error, of which only the code is kept

  This is applied inside the process of the client, so the text does not get as far as
  a caller. The functions here are pure.
  """

  @page_gone -32_001

  @doc """
  `{:ok, result}` or `{:error, reason}` for a decoded reply. The reasons are
  `:page_closed` (Chrome no longer knows the session), `{:cdp_error, code}`
  and `:bad_reply`.
  """
  @spec outcome(map()) :: {:ok, map()} | {:error, term()}
  def outcome(%{"error" => %{"code" => @page_gone}}), do: {:error, :page_closed}

  def outcome(%{"error" => %{"code" => code}}) when is_integer(code),
    do: {:error, {:cdp_error, code}}

  def outcome(%{"error" => _error}), do: {:error, :cdp_error}
  def outcome(%{"result" => %{} = result}), do: {:ok, scrub(result)}
  def outcome(_reply), do: {:error, :bad_reply}

  @doc """
  The result without the text of an exception: when the script threw, the result is
  only `%{"exceptionDetails" => %{"lineNumber" => l, "columnNumber" => c}}`.
  """
  @spec scrub(map()) :: map()
  def scrub(%{"exceptionDetails" => details}) do
    %{
      "exceptionDetails" => %{
        "lineNumber" => position(details, "lineNumber"),
        "columnNumber" => position(details, "columnNumber")
      }
    }
  end

  def scrub(result), do: result

  defp position(%{} = details, key), do: Map.get(details, key)
  defp position(_details, _key), do: nil

  @doc """
  The value of a scrubbed `Runtime.evaluate` result:

    * `{:ok, value}` for a value that came back as JSON (`undefined` is `nil`)
    * `{:ok, %{object_id: id}}` for an object that was kept in the page
    * `{:error, {:exception, %{line: l, column: c}}}` for a script that threw, with
      the numbers counted from zero, as Chrome does
  """
  @spec evaluation(map()) :: {:ok, term()} | {:error, {:exception, map()}}
  def evaluation(%{"exceptionDetails" => details}) do
    {:error, {:exception, %{line: details["lineNumber"], column: details["columnNumber"]}}}
  end

  def evaluation(%{"result" => %{"value" => value}}), do: {:ok, value}
  def evaluation(%{"result" => %{"objectId" => id}}), do: {:ok, %{object_id: id}}
  def evaluation(_result), do: {:ok, nil}

  @doc """
  What `Page.navigate` answered: `{:ok, loader_id}` for a navigation to another
  document, whose load is the one to wait for, `{:ok, nil}` when the document stays
  (only the fragment changed), or `{:error, reason}` when Chrome could not navigate:
  `{:navigation_failed, "net::ERR_..."}`, with the code of Chrome and nothing else.
  """
  @spec navigation(map()) :: {:ok, String.t() | nil} | {:error, term()}
  def navigation(%{"errorText" => text}) when is_binary(text) do
    if text =~ ~r/\Anet::ERR_[A-Z0-9_]+\z/,
      do: {:error, {:navigation_failed, text}},
      else: {:error, :navigation_failed}
  end

  def navigation(%{"loaderId" => loader_id}) when is_binary(loader_id), do: {:ok, loader_id}
  def navigation(_result), do: {:ok, nil}
end
