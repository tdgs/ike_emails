defmodule IkeEmails.Bank.Driver.Console do
  @moduledoc """
  What the driver lets out of the console of the bank's page: the progress lines of
  `priv/bank/statements.js`, and nothing else.

  The script says what it is doing with `console.log("[crawler]", "#3", "request",
  "details of 123")`, and when the call is over with `"#3", "done in", "812 ms"`. When a
  call fails it says `"#3", "failed in", "812 ms", "HTTP 500: ..."`, and that last text is
  the start of what the bank answered, up to 500 characters of it. So the console of the
  page is not for a log, and the driver passes on only what it knows to be safe:

    * A message counts only when its first argument is exactly `[crawler]`, as the page
      scripts tag theirs. What the bank's own application prints is not looked at.
    * Of those, only a line whose first word, after the number of the request (`#3`), is
      `request` or `done in`. The decision is made on that argument and not on the text
      of the whole line, so that the text of a failure cannot pass as a progress line by
      containing `done in`.
    * An argument that is not a string, a number or a boolean (an object, `null`) makes
      the whole message count for nothing.

  `line/1` is the filter, and is pure. `start/1` is the process that applies it to the
  events of Chrome and calls the function of the caller with each line that passes.
  """

  @tag "[crawler]"

  @doc """
  The line for the params of a `Runtime.consoleAPICalled` event, as `{:ok, line}`, or
  `:ignore` when it is not a progress line of the crawler.

      iex> IkeEmails.Bank.Driver.Console.line(%{
      ...>   "args" => [
      ...>     %{"type" => "string", "value" => "[crawler]"},
      ...>     %{"type" => "string", "value" => "#1"},
      ...>     %{"type" => "string", "value" => "done in"},
      ...>     %{"type" => "string", "value" => "812 ms"}
      ...>   ]
      ...> })
      {:ok, "#1 done in 812 ms"}
  """
  @spec line(map()) :: {:ok, String.t()} | :ignore
  def line(%{"args" => args}) when is_list(args) do
    with {:ok, words} <- words(args),
         [@tag | rest] <- words do
      progress(rest)
    else
      _not_ours -> :ignore
    end
  end

  def line(_params), do: :ignore

  defp words(args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, words} ->
      case word(arg) do
        {:ok, word} -> {:cont, {:ok, [word | words]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, words} -> {:ok, Enum.reverse(words)}
      :error -> :error
    end
  end

  # A console argument is a remote object: a primitive has its value, anything else a
  # description. Only the primitives are read, an object is not for a line
  defp word(%{"value" => value}) when is_binary(value), do: {:ok, String.trim(value)}
  defp word(%{"value" => value}) when is_number(value), do: {:ok, to_string(value)}
  defp word(%{"value" => value}) when is_boolean(value), do: {:ok, to_string(value)}
  defp word(_arg), do: :error

  defp progress(words) do
    {number, words} = number(words)

    case words do
      ["request" <> _ | _] -> {:ok, Enum.join(number ++ words, " ")}
      ["done in" <> _ | _] -> {:ok, Enum.join(number ++ words, " ")}
      _other -> :ignore
    end
  end

  defp number(["#" <> digits = number | words]) do
    if digits != "" and String.match?(digits, ~r/\A[0-9]+\z/),
      do: {[number], words},
      else: {[], [number | words]}
  end

  defp number(words), do: {[], words}

  @doc """
  Starts the process that reads the events of Chrome sent to it
  (`IkeEmails.Chrome.subscribe/2`), and calls `relay` with the line of each one that
  `line/1` lets through. It ends with the process that started it, or on `stop/1`.

  `relay` runs in that process, and what it raises or throws is dropped, so a function
  of the caller cannot end the crawl. Returns the pid to subscribe.
  """
  @spec start((String.t() -> term())) :: pid()
  def start(relay) when is_function(relay, 1) do
    owner = self()

    {:ok, pid} =
      Task.start(fn ->
        monitor = Process.monitor(owner)
        loop(relay, monitor)
      end)

    pid
  end

  @doc "Ends the process of `start/1`. It is `:ok` also for `nil` and for one that is gone."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp loop(relay, monitor) do
    receive do
      {:chrome_event, "Runtime.consoleAPICalled", params, _session} ->
        pass_on(params, relay)
        loop(relay, monitor)

      {:DOWN, ^monitor, :process, _owner, _reason} ->
        :ok

      :stop ->
        :ok

      _other ->
        loop(relay, monitor)
    end
  end

  defp pass_on(params, relay) do
    with {:ok, line} <- line(params) do
      relay.(line)
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
