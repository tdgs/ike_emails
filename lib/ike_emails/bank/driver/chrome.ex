defmodule IkeEmails.Bank.Driver.Chrome do
  @moduledoc """
  The bank driver (`IkeEmails.Bank.Driver`) that works with a real browser: it logs in to
  myAlpha Web through the login page, and reads the statements by calling the bank's own
  endpoints from inside the logged in page, with the scripts of `priv/bank`
  (`IkeEmails.Bank.Alpha.Script`). It is the crawler written in Gleam, step by step: the
  same page, the same selectors, the same waits.

  The browser is `IkeEmails.Chrome`, and nothing else in the app uses it. The page is
  driven by the functions of the scripts, and what is typed in is passed only as the
  arguments of one of them (never put into the text of a script), and the user name and
  the password only as an `IkeEmails.Chrome.Secret`, which does not show what it holds.

  ## The session

  `open/1` returns the session, a map that the caller only passes back. It holds the
  browser, the module that drives it, the options, and a small process that keeps the
  current page, because a login ends with `:ok` and the calls that follow need the page it
  made. The processes are linked to the one that opened the session, so they end with it.
  Only one process should use a session at a time. `login_page/1` and `current_page/1`
  are not part of the behaviour: `mix bank.probe` uses them to look at the page.

  The options of `open/1`:

    * `:user_data_dir` - the profile of the browser. Without it a directory of its own is
      made under the temporary directory, named `bank-` and random, that only the user of
      the node can read (`0700`), and `close/1` removes it with what the browser wrote in
      it. A directory that is given is the caller's, it is used as it is, and it is kept
    * `:isolated` - whether the login page is opened in a browser context of its own (see
      `IkeEmails.Chrome.new_page/2`), in which Chrome writes nothing to the profile: not
      the user name that is typed in, not what the page keeps in its local storage. That
      matters for the profile that the driver makes, which stays on the disk when the node
      is killed before `close/1` (the browser ends then, the directory does not), so it is
      `true` for it. It is `false` for a directory that is given, because that profile is
      kept on purpose, to be used again: it is how the bank remembers a device, and how the
      crawl on a Mac stays logged in to the browser between runs. What the page wrote
      there is on the disk, with the user name among it
    * `:headless` - `true`; `false` shows the window
    * `:chrome_opts` - more options for `IkeEmails.Chrome.start_link/1`, such as
      `:chrome_path`, `:no_sandbox` and `:lang`. `:user_data_dir` and `:headless` are not
      taken from it
    * `:on_console` - a function of one argument that gets the progress lines that the
      scripts print, see `IkeEmails.Bank.Driver.Console`. Without it nothing of the console
      of the page is read, and nothing is logged by the driver either way
    * `:poll_interval` - how long to wait between two looks at the page, 250 milliseconds
    * `:login_timeout`, `:element_timeout`, `:logout_timeout` - how long to wait for the
      bank to answer the login (120 seconds), for an element of the login page to appear
      (30 seconds), and for the logout to leave the app (30 seconds)
    * `:chrome` - the module that drives the browser, `IkeEmails.Chrome`. A test gives a
      module with the same functions (`start_link/1`, `stop/1`, `new_page/2`,
      `close_page/3`, `navigate/4`, `call_script/6`, `subscribe/2`) and no browser is run
    * `:login_url` - the page that the login starts from. It is the one of myAlpha Web,
      and is another one only in the tests, which serve a page of their own

  A directory that the driver made is removed by `close/1` alone. Nothing here looks for
  the ones that an earlier node left, because several syncs can run at once and cannot tell
  those from the directory of another: that is for the start of the application.

  ## Errors

  Every function returns `{:error, reason}` and the reason holds nothing from the bank.
  The ones that the crawl tells apart are those of `c:IkeEmails.Bank.Driver.login/2`.
  Besides them:

    * `:timeout` - something that was waited for did not come in time: the login form,
      the button, the end of the logout, a call of the browser, the answer of the bank to
      the request for the login page
    * `:no_page` - there is no page yet, because there was no login
    * `:unexpected_response` - the script answered with something else than what it
      should have
    * `:too_many_ids` - `fetch_details/3` takes 20 ids at most
    * `{:exception, %{line: l, column: c}}` - a script threw. Chrome says why in a text,
      and the text is never passed on (it can repeat what the script was given)
    * the errors of `IkeEmails.Chrome`: `:chrome_exited`, `:page_closed`,
      `{:navigation_failed, "net::ERR_..."}`, `{:cdp_error, code}` and the rest

  While it waits, any error of a look at the page means to look again, as in the crawler
  in Gleam: the page is changing, and a script that is evaluated in the middle of it can
  fail. Two do not: when the browser or the page is gone, there is nothing to wait for.

  The text of the error that the login page shows is read only to tell whether it says
  that the account is in use (`IkeEmails.Bank.Alpha.Login.session_in_use?/1`). It is not
  returned, nor kept, nor logged.
  """

  @behaviour IkeEmails.Bank.Driver

  alias IkeEmails.Bank.Alpha.Login
  alias IkeEmails.Bank.Alpha.Script
  alias IkeEmails.Bank.Credentials
  alias IkeEmails.Bank.Driver.Console
  alias IkeEmails.Chrome.Page
  alias IkeEmails.Chrome.Secret

  @login_url "https://secure.alpha.gr/myAlphaWeb/business/"
  @username_selector "input[placeholder*='username']"
  @password_selector "input[type='password']"
  @submit_selector "button.login-button:not([disabled])"
  @logout_selector "a.lo"

  @navigation_timeout :timer.seconds(30)
  @element_timeout :timer.seconds(30)
  @login_timeout :timer.seconds(120)
  @logout_timeout :timer.seconds(30)
  @poll_interval 250
  # A look at the page, while it is waited for
  @look_timeout :timer.seconds(10)

  # A statement fetch is as many calls as the range needs, and can take minutes
  @statements_timeout :timer.minutes(5)
  @details_timeout :timer.minutes(2)
  @list_timeout :timer.minutes(2)
  @estatement_timeout :timer.minutes(2)

  # A call that takes longer than the browser allows is lost, with all that it fetched
  @details_batch 20
  # The calls to the details that run at once; the bank blocks when it is asked too fast
  @details_concurrency 2

  @type session :: %{
          module: module(),
          chrome: pid(),
          pages: pid(),
          relay: pid() | nil,
          profile_dir: String.t(),
          remove_profile: boolean(),
          isolated: boolean(),
          login_url: String.t(),
          poll_interval: non_neg_integer(),
          login_timeout: non_neg_integer(),
          element_timeout: non_neg_integer(),
          logout_timeout: non_neg_integer()
        }

  ## Open and close

  @doc """
  Starts the browser and returns the session. `{:error, :chrome_not_found}` when there is
  no Chrome to run, and `{:error, {:profile_dir, posix}}` when the directory of the
  profile cannot be made. See the module for the options.
  """
  @impl true
  @spec open(keyword()) :: {:ok, session()} | {:error, term()}
  def open(opts) do
    with {:ok, profile_dir, created?} <- profile_dir(Keyword.get(opts, :user_data_dir)) do
      case start(profile_dir, created?, opts) do
        {:ok, _session} = ok ->
          ok

        {:error, _reason} = error ->
          if created?, do: File.rm_rf(profile_dir)
          error
      end
    end
  end

  defp profile_dir(nil) do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(System.tmp_dir!(), "bank-" <> random)

    with :ok <- File.mkdir(dir),
         :ok <- chmod(dir) do
      {:ok, dir, true}
    else
      {:error, posix} -> {:error, {:profile_dir, posix}}
    end
  end

  defp profile_dir(dir) when is_binary(dir), do: {:ok, dir, false}

  defp chmod(dir) do
    with {:error, _posix} = error <- File.chmod(dir, 0o700) do
      File.rmdir(dir)
      error
    end
  end

  defp start(profile_dir, created?, opts) do
    module = Keyword.get(opts, :chrome, IkeEmails.Chrome)

    chrome_opts =
      opts
      |> Keyword.get(:chrome_opts, [])
      |> Keyword.merge(user_data_dir: profile_dir, headless: Keyword.get(opts, :headless, true))

    with {:ok, chrome} <- module.start_link(chrome_opts),
         {:ok, pages} <- Agent.start_link(fn -> nil end) do
      session = %{
        module: module,
        chrome: chrome,
        pages: pages,
        relay: nil,
        profile_dir: profile_dir,
        remove_profile: created?,
        isolated: Keyword.get(opts, :isolated, created?),
        login_url: Keyword.get(opts, :login_url, @login_url),
        poll_interval: Keyword.get(opts, :poll_interval, @poll_interval),
        login_timeout: Keyword.get(opts, :login_timeout, @login_timeout),
        element_timeout: Keyword.get(opts, :element_timeout, @element_timeout),
        logout_timeout: Keyword.get(opts, :logout_timeout, @logout_timeout)
      }

      relay(session, Keyword.get(opts, :on_console))
    end
  end

  defp relay(session, nil), do: {:ok, session}

  defp relay(session, on_console) when is_function(on_console, 1) do
    relay = Console.start(on_console)

    case session.module.subscribe(session.chrome, relay) do
      :ok ->
        {:ok, %{session | relay: relay}}

      {:error, _reason} = error ->
        Console.stop(relay)
        close(session)
        error
    end
  end

  @doc """
  Ends the browser, and removes the profile if the driver made it. It is `:ok` also when
  the browser is gone already, and may be called twice.
  """
  @impl true
  @spec close(session()) :: :ok
  def close(session) do
    _ = close_page(session)
    Console.stop(session.relay)
    session.module.stop(session.chrome)
    stop_pages(session.pages)
    if session.remove_profile, do: File.rm_rf(session.profile_dir)
    :ok
  end

  defp stop_pages(pages) do
    Agent.stop(pages)
  catch
    :exit, _reason -> :ok
  end

  ## Pages

  @doc """
  The page the session is on: the one the last login made.
  """
  @spec current_page(session()) :: {:ok, Page.t()} | {:error, :no_page}
  def current_page(session) do
    case Agent.get(session.pages, & &1) do
      %Page{} = page -> {:ok, page}
      nil -> {:error, :no_page}
    end
  catch
    # The session is closed
    :exit, _reason -> {:error, :no_page}
  end

  @doc """
  Opens a new page on the login page of the bank, and closes the one that was there (with
  its browser context, see the option `:isolated`). This is how `login/2` starts, and
  `mix bank.probe` uses it to look at the page before it logs in.

  It returns the page once the bank has answered the request for it, which is waited for 30
  seconds at most, and not once the page has loaded: a page whose images or scripts do not
  come, as from a server with no way out to the network, would never have, and the form
  that the login needs may be there long before. What the caller needs on the page it waits
  for itself, as `login/2` does for the form.
  """
  @spec login_page(session()) :: {:ok, Page.t()} | {:error, term()}
  def login_page(session) do
    _ = close_page(session)

    with {:ok, page} <- session.module.new_page(session.chrome, context(session)),
         :ok <- Agent.update(session.pages, fn _closed -> page end),
         {:ok, _started} <-
           session.module.navigate(session.chrome, page, session.login_url,
             timeout: @navigation_timeout,
             wait: :commit
           ) do
      {:ok, page}
    end
  end

  @doc """
  Waits until the login form is on the page, as `login/2` does: for the time of the option
  `:element_timeout` (30 seconds), looking again every `:poll_interval`. `mix bank.probe`
  uses it to look at the page once the form is drawn, which AngularJS does some time after
  the page is there.
  """
  @spec await_login_form(session(), Page.t()) :: {:ok, :found} | {:error, term()}
  def await_login_form(session, %Page{} = page),
    do: await_visible(session, page, @password_selector)

  defp context(%{isolated: true}), do: [context: :isolated]
  defp context(_session), do: []

  defp close_page(session) do
    with {:ok, page} <- current_page(session) do
      Agent.update(session.pages, fn _page -> nil end)
      session.module.close_page(session.chrome, page, [])
    end
  end

  ## Login

  @doc """
  Logs in, on a page of its own: the one of the last login is closed, and a new one is
  opened on the login page, so that it can be called again after
  `{:error, :session_in_use}`.

  It waits for the form (up to 30 seconds, from the request for the page, whether the page
  has loaded or not), types the user name and the password, waits for the button, which
  stays disabled until the form is valid, and clicks it. Then it waits, up to two minutes,
  until the page has either left the `/auth/` pages (`:ok`) or shows an error. When the
  error says that the account is in use it is `{:error, :session_in_use}`, whatever else
  it says is `{:error, :bad_credentials}`. An error element that has no text yet is looked at
  again, as is an answer of the page that is none of these. A page that does nothing in that
  time, such as one that asks for a code, is `{:error, :timeout}`: the driver does not know
  a second factor yet (`mix bank.probe` is how one is found).
  """
  @impl true
  @spec login(session(), Credentials.t()) :: :ok | {:error, term()}
  def login(session, %Credentials{} = credentials) do
    with {:ok, page} <- login_page(session),
         {:ok, _found} <- await_visible(session, page, @password_selector),
         :ok <- fill(session, page, @username_selector, credentials.username),
         :ok <- fill(session, page, @password_selector, credentials.password),
         # The button stays disabled until the form is valid
         {:ok, _found} <- await_visible(session, page, @submit_selector),
         :ok <- click(session, page, @submit_selector) do
      await_outcome(session, page)
    end
  end

  # The page has two login forms, and the first is hidden: login.js takes a visible element
  defp await_visible(session, page, selector) do
    poll(session, session.element_timeout, fn timeout ->
      case login_script(session, page, "find", %{selector: selector},
             timeout: timeout,
             return_by_value: false
           ) do
        {:ok, %{object_id: _id}} -> {:ok, :found}
        {:ok, _nothing} -> :retry
        {:error, _reason} = error -> error
      end
    end)
  end

  defp fill(session, page, selector, text) do
    args = %{selector: selector, value: Secret.new(text)}

    with {:ok, _filled} <- login_script(session, page, "fill", args, []), do: :ok
  end

  defp click(session, page, selector) do
    with {:ok, _clicked} <- login_script(session, page, "click", %{selector: selector}, []),
         do: :ok
  end

  defp await_outcome(session, page) do
    outcome =
      poll(session, session.login_timeout, fn timeout ->
        case login_script(session, page, "outcome", %{}, timeout: timeout) do
          {:ok, text} when is_binary(text) -> decide(text)
          {:ok, _not_yet} -> :retry
          {:error, _reason} = error -> error
        end
      end)

    case outcome do
      {:ok, :accepted} -> :ok
      {:ok, {:rejected, reason}} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  # The text of the error is read here and goes no further
  defp decide(text) do
    case Jason.decode(text) do
      {:ok, accepted} when accepted == %{} ->
        {:ok, :accepted}

      {:ok, %{"error" => error}} when is_binary(error) and error != "" ->
        if Login.session_in_use?(error),
          do: {:ok, {:rejected, :session_in_use}},
          else: {:ok, {:rejected, :bad_credentials}}

      # An error element that has no text yet, or anything that is not the answer
      _other ->
        :retry
    end
  end

  defp login_script(session, page, function, args, opts) do
    script(session, page, :login, function, args, [user_gesture: true] ++ opts)
  end

  ## Logout

  @doc """
  Clicks the logout icon, and waits, up to 30 seconds, until the browser has left the app.
  The bank allows one session at a time, so this is tried after every crawl.
  """
  @impl true
  @spec logout(session()) :: :ok | {:error, term()}
  def logout(session) do
    with {:ok, page} <- current_page(session),
         {:ok, _clicked} <-
           login_script(session, page, "click", %{selector: @logout_selector}, []),
         {:ok, _left} <- await_left(session, page) do
      :ok
    end
  end

  # The page navigates away, so evaluating meanwhile may fail, and polling tries again
  defp await_left(session, page) do
    poll(session, session.logout_timeout, fn timeout ->
      case login_script(session, page, "leftApp", %{}, timeout: timeout, return_by_value: false) do
        {:ok, %{object_id: _id}} -> {:ok, :left}
        {:ok, _still_there} -> :retry
        {:error, _reason} = error -> error
      end
    end)
  end

  ## Statements

  @doc """
  The statements of the last `days` days, as the JSON text that `fetchStatements` of
  `priv/bank/statements.js` returns. It can take minutes, and is waited for five.
  """
  @impl true
  @spec fetch_statements(session(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_statements(session, iban, days) do
    statements(session, "fetch", %{iban: iban, days: days}, @statements_timeout)
  end

  @doc """
  The details of at most 20 transactions, two calls at a time. The script answers with
  JSON text, which is read into the map of `t:IkeEmails.Bank.Driver.details/0`: the
  entries that came back, how many did not, and the status with which the bank refused
  (401 or 403), if it did. More than 20 ids are `{:error, :too_many_ids}`.
  """
  @impl true
  @spec fetch_details(session(), String.t(), [String.t()]) ::
          {:ok, IkeEmails.Bank.Driver.details()} | {:error, term()}
  def fetch_details(_session, _iban, ids) when length(ids) > @details_batch,
    do: {:error, :too_many_ids}

  def fetch_details(session, iban, ids) do
    args = %{iban: iban, ids: ids, concurrency: @details_concurrency}

    with {:ok, text} <- statements(session, "fetchDetails", args, @details_timeout) do
      read_details(text)
    end
  end

  defp read_details(text) do
    with {:ok, %{"entries" => entries, "failed" => failed, "stopped" => stopped}} <-
           Jason.decode(text),
         true <- is_integer(failed) and failed >= 0,
         true <- stopped in [nil, 401, 403],
         {:ok, entries} <- read_entries(entries) do
      {:ok, %{entries: entries, failed: failed, stopped: stopped}}
    else
      _unexpected -> {:error, :unexpected_response}
    end
  end

  defp read_entries(entries) when is_list(entries) do
    read =
      for %{"id" => id, "json" => json} <- entries,
          is_binary(id),
          is_binary(json),
          do: %{id: id, json: json}

    if length(read) == length(entries), do: {:ok, read}, else: :error
  end

  defp read_entries(_entries), do: :error

  @doc """
  The list of the monthly statements that the bank has issued, as the JSON text that
  `listEStatements` returns.
  """
  @impl true
  @spec list_estatements(session(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def list_estatements(session, iban) do
    statements(session, "listEStatements", %{iban: iban}, @list_timeout)
  end

  @doc """
  The PDF of a monthly statement, as `%{bytes: size, base64: content}`. The page has
  checked that it is a PDF; `IkeEmails.Bank.Alpha.Pdf` checks the size and decodes it.
  """
  @impl true
  @spec fetch_estatement(session(), String.t()) ::
          {:ok, %{bytes: non_neg_integer(), base64: String.t()}} | {:error, term()}
  def fetch_estatement(session, id) do
    with {:ok, text} <- statements(session, "fetchEStatement", %{id: id}, @estatement_timeout) do
      case Jason.decode(text) do
        {:ok, %{"bytes" => bytes, "base64" => base64}}
        when is_integer(bytes) and bytes >= 0 and is_binary(base64) ->
          {:ok, %{bytes: bytes, base64: base64}}

        _unexpected ->
          {:error, :unexpected_response}
      end
    end
  end

  # A function of statements.js, which returns a promise of JSON text
  defp statements(session, function, args, timeout) do
    opts = [await_promise: true, user_gesture: true, timeout: timeout]

    with {:ok, page} <- current_page(session),
         {:ok, text} <- script(session, page, :statements, function, args, opts) do
      if is_binary(text), do: {:ok, text}, else: {:error, :unexpected_response}
    end
  end

  defp script(session, page, name, function, args, opts) do
    session.module.call_script(session.chrome, page, Script.source(name), function, args, opts)
  end

  ## Waiting

  # Calls `look` until it says `{:ok, value}`, for `timeout` milliseconds, and is
  # `{:error, :timeout}` after them. `look` gets the time that is left, to limit the look
  # at the page by it. It says `:retry` to look again, or an error, which is a reason to
  # look again too, except when the browser or the page is gone.
  defp poll(session, timeout, look) do
    until(session, System.monotonic_time(:millisecond) + timeout, look)
  end

  defp until(session, deadline, look) do
    left = deadline - System.monotonic_time(:millisecond)

    case look.(left |> min(@look_timeout) |> max(1)) do
      {:ok, _value} = done ->
        done

      {:error, reason} when reason in [:chrome_exited, :page_closed] ->
        {:error, reason}

      _again when left <= session.poll_interval ->
        {:error, :timeout}

      _again ->
        Process.sleep(session.poll_interval)
        until(session, deadline, look)
    end
  end
end
