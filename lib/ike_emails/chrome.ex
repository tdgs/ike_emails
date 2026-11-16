defmodule IkeEmails.Chrome do
  @moduledoc """
  A browser, Chrome or Chromium, that is driven from Elixir with the DevTools protocol:
  one process per browser. It is what the crawl of the bank logs in with, and nothing
  else in the app uses it.

  Chrome is started with `--remote-debugging-pipe`, which makes it read the commands
  from file descriptor 3 and write the replies and the events to file descriptor 4,
  both as JSON texts that end with a NUL byte (see `IkeEmails.Chrome.Frames`). The
  pipe belongs to this process alone. The other way to drive Chrome,
  `--remote-debugging-port`, opens a port on the machine that any program on it can
  connect to, with no password, and that is the wrong thing to have open while a page
  holds a bank session. The pipe is also what ends the browser: when this process is
  gone, however it went, the pipe is closed, Chrome reads the end of it and exits, so
  no browser process stays behind when the node is killed. The profile directory does:
  it is removed by whoever made it, after `stop/1` (which asks Chrome to close, and
  waits for it, so that the directory is not in use), and when the node was killed it
  stays until something sweeps it.

  Chrome does not inherit the environment of the node, see `IkeEmails.Chrome.Launcher`.
  It needs a user data directory of its own (`:user_data_dir`), which is the one place
  where it writes what a page stored: the cookies, the local storage and the cache of the
  pages, and the user names that were typed into a form, which Chrome keeps for its own
  forms and logins. A page that is opened with `context: :isolated` (see `new_page/2`)
  stores none of it there.

      {:ok, chrome} = IkeEmails.Chrome.start_link(user_data_dir: "/tmp/bank/42-9f3a")
      {:ok, page} = IkeEmails.Chrome.new_page(chrome)
      {:ok, _} = IkeEmails.Chrome.navigate(chrome, page, "https://example.com/")
      {:ok, title} = IkeEmails.Chrome.evaluate(chrome, page, "document.title")
      :ok = IkeEmails.Chrome.stop(chrome)

  ## What the password goes through

  The password of the bank is typed into the page by a script that is evaluated in it,
  so it travels in the text of a command. What is done so that it is not seen on the
  way:

    * It is an `IkeEmails.Chrome.Secret` until the command is built, which is in this
      process (`call_script/6`), as late as it can be. The caller does not hold a string
      that contains it, and a `Secret` does not show what it holds.
    * The process is `:sensitive` (no tracing, no messages or dictionary in
      `Process.info/2` or a crash dump), and `format_status/1` leaves the message that
      holds the arguments out of a crash report.
    * The state holds the calls that wait for an answer as the caller, a timer and the
      name of the command, never its arguments, and never a message from Chrome: the
      part of a message that has arrived is kept in a private table of the process.
      A command is turned into iodata, written to the port, and not kept.
    * What Chrome says about an exception is not passed on, see `IkeEmails.Chrome.Reply`.
    * Nothing is logged and no span is made. The errors are atoms and small tuples that
      hold nothing from a page: no text, no value, no credentials.

  Whoever can run code in the node can still read it from the memory of the process.
  That is out of reach of this.

  ## Errors

  Every call has a deadline (`:timeout` in milliseconds, 30 seconds unless it is given),
  after which it returns `{:error, :timeout}` and is forgotten, so an answer that comes
  late is dropped. Besides it:

    * `{:error, :chrome_exited}` - Chrome ended, or this process did, or it ends while
      the call waits. The process stops when Chrome does, so every call after it
      returns this
    * `{:error, :page_closed}` - the page was closed, or crashed, while a call waited
      for it, or before it
    * `{:error, {:cdp_error, code}}` - Chrome refused a command; the code only
    * `{:error, {:exception, %{line: l, column: c}}}` - the script threw. The text of
      the exception is never returned
    * `{:error, {:navigation_failed, "net::ERR_..."}}` - the page could not be loaded,
      which `navigate/4` tells also with `wait: :commit`
    * `{:error, :invalid_function}` and `{:error, :invalid_arguments}` - see
      `call_script/6`
    * `{:error, :bad_reply}` - Chrome answered with something that was not expected

  ## Options of `start_link/1`

  `IkeEmails.Chrome.Launcher` has them: `:user_data_dir` (required), `:chrome_path`,
  `:headless`, `:lang`, `:no_sandbox` and `:extra_args`.
  """

  use GenServer, restart: :temporary

  alias IkeEmails.Chrome.Frames
  alias IkeEmails.Chrome.Launcher
  alias IkeEmails.Chrome.Page
  alias IkeEmails.Chrome.Reply
  alias IkeEmails.Chrome.Script

  @type chrome :: GenServer.server()

  @default_timeout :timer.seconds(30)
  # The process answers a call that is over its deadline, and the caller waits that
  # much longer for the answer before it gives up on the process
  @reply_margin :timer.seconds(5)
  # How long `stop/1` waits for Chrome to end before the pipe is closed on it
  @stop_grace :timer.seconds(5)

  ## Client

  @doc """
  Starts Chrome and the process that drives it, linked to the caller. When the caller
  ends, so does Chrome.

  Returns `{:ok, pid}`, or `{:error, :chrome_not_found}` or
  `{:error, :user_data_dir_required}`. That Chrome runs is not known until a call is
  made: a path that is not Chrome, or a profile that cannot be used, shows as
  `{:error, :chrome_exited}`.
  """
  @spec start_link(keyword()) ::
          {:ok, pid()} | {:error, :chrome_not_found | :user_data_dir_required}
  def start_link(opts) do
    with {:ok, command} <- Launcher.command(opts) do
      GenServer.start_link(__MODULE__, command)
    end
  end

  @doc """
  Ends the browser: asks it to close, waits for it to exit (a few seconds at most, then
  the pipe is closed on it), and stops the process. The calls that wait return
  `{:error, :chrome_exited}`. It is `:ok` also when it is over already.
  """
  @spec stop(chrome()) :: :ok
  def stop(chrome) do
    GenServer.stop(chrome, :normal, @stop_grace * 3)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Opens a page: creates the target, attaches a session to it, and turns on the events of
  the runtime and of the page, which loading waits for. Options:

    * `:context` - `:default` opens the page in the browser context that Chrome starts
      with, the one that stores in the user data directory what the pages keep: cookies,
      local storage, the cache, the user names typed into forms. `:isolated` makes a context for the
      page alone, as an incognito window is, and nothing of what the page keeps is written
      to the user data directory: it lives in memory, and is gone when the page is closed
      (`close_page/3` disposes of the context) or the browser ends. `:default`
    * `:timeout` - for each step
  """
  @spec new_page(chrome(), keyword()) :: {:ok, Page.t()} | {:error, term()}
  def new_page(chrome, opts \\ []) do
    with {:ok, context_id} <- open_context(chrome, opts),
         {:ok, page} <- open_page(chrome, context_id, opts) do
      {:ok, page}
    end
  end

  defp open_context(chrome, opts) do
    case Keyword.get(opts, :context, :default) do
      :default ->
        {:ok, nil}

      :isolated ->
        case call(chrome, "Target.createBrowserContext", %{}, opts) do
          {:ok, %{"browserContextId" => context_id}} when is_binary(context_id) ->
            {:ok, context_id}

          {:ok, _unexpected} ->
            {:error, :bad_reply}

          {:error, _reason} = error ->
            error
        end

      _other ->
        raise ArgumentError, "the option :context is :default or :isolated"
    end
  end

  defp open_page(chrome, context_id, opts) do
    params = %{url: "about:blank"}
    params = if context_id, do: Map.put(params, :browserContextId, context_id), else: params

    result =
      with {:ok, %{"targetId" => target_id}} <- call(chrome, "Target.createTarget", params, opts),
           {:ok, page} <- attach(chrome, target_id, context_id, opts) do
        {:ok, page}
      else
        {:error, _reason} = error -> error
        _unexpected -> {:error, :bad_reply}
      end

    # A context that has no page would stay open until the browser ends
    with {:error, _reason} <- result do
      _ = dispose_context(chrome, context_id, opts)
      result
    end
  end

  defp attach(chrome, target_id, context_id, opts) do
    result =
      with {:ok, %{"sessionId" => session_id}} <-
             call(chrome, "Target.attachToTarget", %{targetId: target_id, flatten: true}, opts),
           page = %Page{
             target_id: target_id,
             session_id: session_id,
             browser_context_id: context_id
           },
           :ok <- enable(chrome, page, opts) do
        {:ok, page}
      else
        {:error, _reason} = error -> error
        _unexpected -> {:error, :bad_reply}
      end

    # A page that could not be set up would stay open until the browser ends
    with {:error, _reason} <- result do
      _ = call(chrome, "Target.closeTarget", %{targetId: target_id}, opts)
      result
    end
  end

  defp dispose_context(_chrome, nil, _opts), do: :ok

  defp dispose_context(chrome, context_id, opts) do
    with {:ok, _result} <-
           call(chrome, "Target.disposeBrowserContext", %{browserContextId: context_id}, opts) do
      :ok
    end
  end

  defp enable(chrome, page, opts) do
    opts = Keyword.put(opts, :session, page)

    [
      {"Runtime.enable", %{}},
      {"Page.enable", %{}},
      {"Page.setLifecycleEventsEnabled", %{enabled: true}}
    ]
    |> Enum.reduce_while(:ok, fn {method, params}, :ok ->
      case call(chrome, method, params, opts) do
        {:ok, _result} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Closes the page, and disposes of its browser context when it has one of its own (see
  `new_page/2`), also when the page could not be closed because it was gone already.
  Options: `:timeout`.
  """
  @spec close_page(chrome(), Page.t(), keyword()) :: :ok | {:error, term()}
  def close_page(chrome, %Page{} = page, opts \\ []) do
    closed =
      with {:ok, _result} <- call(chrome, "Target.closeTarget", %{targetId: page.target_id}, opts),
           do: :ok

    disposed = dispose_context(chrome, page.browser_context_id, opts)

    with :ok <- closed, do: disposed
  end

  @doc """
  Loads `url` in the page and waits until it has loaded. `{:ok, %{loader_id: id}}`,
  where the id is `nil` when only the fragment of the address changed.

  What is waited for is the `load` of the document that this navigation started, by the
  id of its loader: the `load` of the page that was there before it cannot end the wait.
  A page that does not load in time is `{:error, :timeout}`. Options:

    * `:wait` - `:load` waits for the `load` of the document, which comes when all it
      fetches has arrived: a page with an image that never comes does not load, and a
      document that replaces itself while it is read never has the `load` of the first.
      `:commit` returns when Chrome has answered the navigation, which is when the
      document has started (the page is not yet read to the end, and may be replaced), for
      a caller that looks at the page and waits for what it needs itself. A navigation
      that Chrome cannot make is `{:error, {:navigation_failed, text}}` with both. `:load`
    * `:timeout` - in milliseconds, 30 seconds
  """
  @spec navigate(chrome(), Page.t(), String.t(), keyword()) ::
          {:ok, %{loader_id: String.t() | nil}} | {:error, term()}
  def navigate(chrome, %Page{} = page, url, opts \\ []) when is_binary(url) do
    timeout = timeout(opts)
    request(chrome, {:navigate, page.session_id, url, timeout, wait(opts)}, timeout)
  end

  defp wait(opts) do
    case Keyword.get(opts, :wait, :load) do
      wait when wait in [:load, :commit] -> wait
      _other -> raise ArgumentError, "the option :wait is :load or :commit"
    end
  end

  @doc """
  Evaluates the JavaScript `expression` (a string or iodata) in the page.

  Returns `{:ok, value}`, the value as JSON decoded (`undefined` is `nil`), or, with
  `return_by_value: false`, `{:ok, %{object_id: id}}` for an object that stays in the
  page. A script that throws is `{:error, {:exception, %{line: l, column: c}}}`, counted
  from zero, and nothing else of the exception.

  A script that runs is not stopped when the call times out. Options:

    * `:await_promise` - waits for a promise to settle and returns its value; `false`
    * `:user_gesture` - runs as if the user had acted, which pages want for a click that
      opens a window or a download; `false`
    * `:return_by_value` - `true`
    * `:timeout` - in milliseconds, 30 seconds

  The expression is held by the process that calls this until it is sent. For a script
  that is given a credential use `call_script/6`.
  """
  @spec evaluate(chrome(), Page.t(), iodata(), keyword()) :: {:ok, term()} | {:error, term()}
  def evaluate(chrome, %Page{} = page, expression, opts \\ []) do
    evaluation = evaluation(opts)

    with {:ok, result} <-
           request(
             chrome,
             {:evaluate, page.session_id, expression, evaluation},
             evaluation.timeout
           ) do
      Reply.evaluation(result)
    end
  end

  @doc """
  Calls `function` of `source` with `args`, in the page, and returns what `evaluate/4`
  does, with the same options.

  `source` is a script that is an expression whose value is an object of functions
  (`priv/bank/login.js` is one). `args` is the one argument of the function, as JSON: a
  map for an object. It may hold `IkeEmails.Chrome.Secret` values anywhere, and they are
  turned into their strings by the process of the client, when the command is built, see
  `IkeEmails.Chrome.Script`. Neither the arguments nor what is wrong with them is in the
  error: `{:error, :invalid_arguments}` for arguments that are not JSON,
  `{:error, :invalid_function}` for a function that is not a name.
  """
  @spec call_script(chrome(), Page.t(), iodata(), String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call_script(chrome, %Page{} = page, source, function, args, opts \\ []) do
    evaluation = evaluation(opts)

    with {:ok, result} <-
           request(
             chrome,
             {:call_script, page.session_id, source, function, args, evaluation},
             evaluation.timeout
           ) do
      Reply.evaluation(result)
    end
  end

  @doc """
  A command of the protocol, as `{:ok, result}` where the result is the decoded map of
  the reply. The commands of a page go with `session: page`; without it the command is
  the browser's. Options: `:session` and `:timeout`.

      IkeEmails.Chrome.call(chrome, "Browser.getVersion")

  The text of an exception in the result is left out, see `IkeEmails.Chrome.Reply`.
  """
  @spec call(chrome(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(chrome, method, params \\ %{}, opts \\ []) when is_binary(method) do
    timeout = timeout(opts)
    session = session_id(Keyword.get(opts, :session))
    request(chrome, {:command, method, params, session, timeout}, timeout)
  end

  @doc """
  Sends `subscriber` (the caller) every event of the browser as
  `{:chrome_event, method, params, session_id}`, where the session is `nil` for the
  events of the browser itself. It is dropped when it ends.

  The events of the console of a page come when it has `Runtime.enable`, which
  `new_page/2` has done. They hold what the page printed, so whoever receives them
  keeps what is not for the logs out of them.
  """
  @spec subscribe(chrome(), pid()) :: :ok | {:error, :chrome_exited}
  def subscribe(chrome, subscriber \\ self()) when is_pid(subscriber) do
    request(chrome, {:subscribe, subscriber}, @default_timeout)
  end

  defp request(chrome, message, timeout) do
    GenServer.call(chrome, message, timeout + @reply_margin)
  catch
    # Not the exit itself, which holds the message
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :chrome_exited}
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  defp session_id(nil), do: nil
  defp session_id(%Page{session_id: session_id}), do: session_id
  defp session_id(session_id) when is_binary(session_id), do: session_id

  defp evaluation(opts) do
    %{
      await_promise: Keyword.get(opts, :await_promise, false),
      user_gesture: Keyword.get(opts, :user_gesture, false),
      return_by_value: Keyword.get(opts, :return_by_value, true),
      timeout: timeout(opts)
    }
  end

  ## Server

  @impl true
  def init(%{executable: executable, args: args}) do
    Process.flag(:sensitive, true)
    # To tell the callers that Chrome ended, and to close it, before this one ends
    Process.flag(:trap_exit, true)

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :nouse_stdio, :exit_status, {:args, args}]
      )

    state = %{
      port: port,
      # The part of a message from Chrome that has arrived, see partial/1
      frames: :ets.new(:frames, [:private]),
      next_id: 1,
      # id => {from, timer, method, session}. A navigation that has been answered waits
      # for its load as {:load, loader_id} in place of the method, and one that does not
      # wait for it is :navigate_commit
      pending: %{},
      subscribers: %{},
      # The loader of the last `load` in a session, for one that came before the answer
      loaded: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:command, method, params, session, timeout}, from, state) do
    send_command(state, from, method, params, session, timeout)
  end

  def handle_call({:evaluate, session, expression, evaluation}, from, state) do
    evaluate(state, from, session, expression, evaluation)
  end

  def handle_call({:call_script, session, source, function, args, evaluation}, from, state) do
    case Script.call(source, function, args) do
      {:ok, expression} -> evaluate(state, from, session, expression, evaluation)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:navigate, session, url, timeout, wait}, from, state) do
    kind = if wait == :commit, do: :navigate_commit, else: "Page.navigate"
    send_command(state, from, "Page.navigate", %{url: url}, session, timeout, kind)
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, subscriber, fn -> Process.monitor(subscriber) end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {frames, partial} = Frames.push(partial(state), data)
    :ets.insert(state.frames, {:partial, partial})

    {:noreply, Enum.reduce(frames, state, &handle_frame/2)}
  end

  def handle_info({:deadline, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _timer, _method, _session}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  # The callers are told by terminate/2. There is no port to close any more
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:DOWN, _ref, :process, subscriber, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, subscriber)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = fail_all(state, :chrome_exited)
    close_port(state.port)
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp evaluate(state, from, session, expression, evaluation) do
    case text(expression) do
      {:ok, text} ->
        params = %{
          expression: text,
          awaitPromise: evaluation.await_promise,
          userGesture: evaluation.user_gesture,
          returnByValue: evaluation.return_by_value
        }

        send_command(state, from, "Runtime.evaluate", params, session, evaluation.timeout)

      :error ->
        {:reply, {:error, :invalid_arguments}, state}
    end
  end

  # Not iodata would print the expression in the crash of this process
  defp text(expression) do
    {:ok, IO.iodata_to_binary(expression)}
  rescue
    ArgumentError -> :error
  end

  # The command is encoded to iodata and written, and that is all that is kept of it.
  # What the call is waiting for is `kind`, which is the method unless it is told
  defp send_command(state, from, method, params, session, timeout, kind \\ nil) do
    id = state.next_id

    with {:ok, json} <- encode(id, method, params, session),
         :ok <- write(state.port, Frames.encode(json)) do
      timer = Process.send_after(self(), {:deadline, id}, timeout)
      pending = Map.put(state.pending, id, {from, timer, kind || method, session})
      {:noreply, %{state | next_id: id + 1, pending: pending}}
    else
      :invalid -> {:reply, {:error, :invalid_arguments}, state}
      :closed -> {:stop, :normal, {:error, :chrome_exited}, state}
    end
  end

  defp encode(id, method, params, session) do
    command = %{id: id, method: method, params: params}
    command = if session, do: Map.put(command, :sessionId, session), else: command

    case Jason.encode_to_iodata(command) do
      {:ok, json} -> {:ok, json}
      {:error, _exception} -> :invalid
    end
  end

  # An exception of a closed port would print the command in its stacktrace
  defp write(port, frame) do
    Port.command(port, frame)
    :ok
  rescue
    ArgumentError -> :closed
  end

  defp partial(state) do
    case :ets.lookup(state.frames, :partial) do
      [{:partial, chunks}] -> chunks
      [] -> Frames.new()
    end
  end

  defp handle_frame(frame, state) do
    case Jason.decode(frame) do
      {:ok, message} -> handle_message(message, state)
      {:error, _exception} -> state
    end
  end

  defp handle_message(%{"id" => id} = message, state) when is_integer(id) do
    case Map.pop(state.pending, id) do
      # It timed out, or was failed, or is not one of ours
      {nil, _pending} -> state
      {entry, pending} -> settle(entry, id, Reply.outcome(message), %{state | pending: pending})
    end
  end

  defp handle_message(%{"method" => method} = message, state) when is_binary(method) do
    params = Map.get(message, "params", %{})
    session = Map.get(message, "sessionId")

    for subscriber <- Map.keys(state.subscribers) do
      send(subscriber, {:chrome_event, method, params, session})
    end

    event(method, params, session, state)
  end

  defp handle_message(_message, state), do: state

  # A navigation is answered when the document has loaded, not when it has started
  defp settle({from, timer, "Page.navigate", session} = entry, id, {:ok, result}, state) do
    case Reply.navigation(result) do
      {:ok, nil} ->
        finish(entry, {:ok, %{loader_id: nil}})
        state

      {:ok, loader_id} ->
        if Map.get(state.loaded, session) == loader_id do
          finish(entry, {:ok, %{loader_id: loader_id}})
          state
        else
          waiting = {from, timer, {:load, loader_id}, session}
          %{state | pending: Map.put(state.pending, id, waiting)}
        end

      {:error, _reason} = error ->
        finish(entry, error)
        state
    end
  end

  # ... or when it has started, if the caller does not want to wait for more
  defp settle({_from, _timer, :navigate_commit, _session} = entry, _id, {:ok, result}, state) do
    case Reply.navigation(result) do
      {:ok, loader_id} -> finish(entry, {:ok, %{loader_id: loader_id}})
      {:error, _reason} = error -> finish(entry, error)
    end

    state
  end

  defp settle(entry, _id, outcome, state) do
    finish(entry, outcome)
    state
  end

  defp finish({from, timer, _method, _session}, outcome) do
    Process.cancel_timer(timer)
    GenServer.reply(from, outcome)
  end

  defp event("Page.lifecycleEvent", %{"name" => "load", "loaderId" => loader_id}, session, state) do
    {done, pending} =
      Enum.split_with(state.pending, fn {_id, {_from, _timer, method, entry_session}} ->
        method == {:load, loader_id} and entry_session == session
      end)

    Enum.each(done, fn {_id, entry} -> finish(entry, {:ok, %{loader_id: loader_id}}) end)

    %{state | pending: Map.new(pending), loaded: Map.put(state.loaded, session, loader_id)}
  end

  defp event("Target.detachedFromTarget", %{"sessionId" => gone}, _session, state)
       when is_binary(gone),
       do: close_session(state, gone)

  defp event("Inspector.targetCrashed", _params, session, state) when is_binary(session),
    do: close_session(state, session)

  defp event(_method, _params, _session, state), do: state

  defp close_session(state, session) do
    {gone, pending} =
      Enum.split_with(state.pending, fn {_id, {_from, _timer, _method, entry_session}} ->
        entry_session == session
      end)

    Enum.each(gone, fn {_id, entry} -> finish(entry, {:error, :page_closed}) end)

    %{state | pending: Map.new(pending), loaded: Map.delete(state.loaded, session)}
  end

  defp fail_all(state, reason) do
    Enum.each(state.pending, fn {_id, entry} -> finish(entry, {:error, reason}) end)
    %{state | pending: %{}}
  end

  # Asks Chrome to close, and waits for it, so that its profile is not in use when
  # this returns. Whatever it does, closing the port ends it
  defp close_port(nil), do: :ok

  defp close_port(port) do
    if Port.info(port) do
      _ = write(port, Frames.encode(~s({"id":0,"method":"Browser.close"})))

      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        @stop_grace -> :ok
      end

      if Port.info(port), do: Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
