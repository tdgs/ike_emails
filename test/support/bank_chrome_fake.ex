defmodule IkeEmails.BankChromeFake do
  @moduledoc """
  A browser for the tests of `IkeEmails.Bank.Driver.Chrome`, given to it as `chrome:`. It has
  the functions of `IkeEmails.Chrome` that the driver uses, runs nothing, and answers
  from a script:

      {:ok, session} = Chrome.open(chrome: IkeEmails.BankChromeFake)
      IkeEmails.BankChromeFake.respond(session.chrome, "outcome", [{:ok, nil}, {:ok, "{}"}])

  `respond/3` gives the answers of a function of a script (`"find"`, `"outcome"`,
  `"fetch"`, ...) one after the other, and the last one for every call after them. A
  function without answers gets a default that lets a login through: the element is
  found, the click and the fill do nothing, the outcome is `{}` and the app is left.
  `"navigate"` can be answered in the same way.

  A page that is opened with `context: :isolated` gets a browser context of its own,
  `"context-1"`, `"context-2"`, ..., in `browser_context_id`, and the page of the default
  context has none.

  Every call is recorded, with its arguments as they were given, so that a test can see
  what the driver sent (a password must be a `IkeEmails.Chrome.Secret`, and not a string):
  `calls/2`. The options of `start_link/1` are `:start_error` (it fails with it), `:notify`
  (a pid that gets `{:chrome_start, opts}`) and `:replies` (a map for `respond/3`).
  """

  alias IkeEmails.Chrome.Page

  @defaults %{
    "find" => {:ok, %{object_id: "node"}},
    "leftApp" => {:ok, %{object_id: "body"}},
    "outcome" => {:ok, "{}"}
  }

  def start_link(opts) do
    if pid = Keyword.get(opts, :notify), do: send(pid, {:chrome_start, opts})

    case Keyword.get(opts, :start_error) do
      nil ->
        replies = Keyword.get(opts, :replies, %{})

        Agent.start_link(fn ->
          %{opts: opts, calls: [], pages: 0, subscribers: [], replies: replies}
        end)

      reason ->
        {:error, reason}
    end
  end

  def stop(chrome) do
    record(chrome, :stop)
  catch
    :exit, _reason -> :ok
  end

  def new_page(chrome, opts) do
    page =
      Agent.get_and_update(chrome, fn state ->
        n = state.pages + 1
        context = if opts[:context] == :isolated, do: "context-#{n}"

        page = %Page{
          target_id: "target-#{n}",
          session_id: "session-#{n}",
          browser_context_id: context
        }

        {page, %{state | pages: n, calls: [{:new_page, page, opts} | state.calls]}}
      end)

    {:ok, page}
  end

  def close_page(chrome, %Page{} = page, opts) do
    record(chrome, {:close_page, page, opts})
  end

  def navigate(chrome, %Page{} = page, url, opts) do
    record(chrome, {:navigate, page, url, opts})

    case next_reply(chrome, "navigate") do
      nil -> {:ok, %{loader_id: "loader"}}
      reply -> reply
    end
  end

  def call_script(chrome, %Page{} = page, source, function, args, opts) do
    record(chrome, {:call_script, page, source, function, args, opts})

    case next_reply(chrome, function) do
      nil -> Map.get(@defaults, function, {:ok, nil})
      reply -> reply
    end
  end

  def subscribe(chrome, pid) do
    record(chrome, {:subscribe, pid})
  end

  @doc "Sets the answers of a function, see the module."
  def respond(chrome, function, replies) when is_list(replies) do
    Agent.update(chrome, fn state ->
      %{state | replies: Map.put(state.replies, function, replies)}
    end)
  end

  @doc """
  The calls so far, in order, as tuples: `{:new_page, page, opts}`, `{:close_page, page, opts}`,
  `{:navigate, page, url, opts}`, `{:call_script, page, source, function, args, opts}`,
  `{:subscribe, pid}` and `:stop`. With a name (`:call_script`, `:stop`, ...) only those.
  """
  def calls(chrome, name \\ nil) do
    calls = chrome |> Agent.get(& &1.calls) |> Enum.reverse()

    case name do
      nil -> calls
      name -> Enum.filter(calls, &(&1 == name or (is_tuple(&1) and elem(&1, 0) == name)))
    end
  end

  @doc "The calls of the script functions, as `{function, args}`."
  def scripts(chrome) do
    for {:call_script, _page, _source, function, args, _opts} <- calls(chrome),
        do: {function, args}
  end

  @doc "Sends the event, as Chrome does, to the processes that subscribed."
  def emit(chrome, method, params, session_id \\ "session-1") do
    for {:subscribe, pid} <- calls(chrome, :subscribe) do
      send(pid, {:chrome_event, method, params, session_id})
    end

    :ok
  end

  defp record(chrome, call) do
    Agent.update(chrome, fn state -> %{state | calls: [call | state.calls]} end)
  end

  defp next_reply(chrome, function) do
    Agent.get_and_update(chrome, fn state ->
      case Map.get(state.replies, function) do
        nil -> {nil, state}
        [reply] -> {reply, state}
        [reply | rest] -> {reply, %{state | replies: Map.put(state.replies, function, rest)}}
      end
    end)
  end
end
