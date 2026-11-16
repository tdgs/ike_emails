defmodule Mix.Tasks.Bank.Probe do
  @shortdoc "Looks at the login page of the bank, and stores nothing"

  @moduledoc """
  A first cut of the real driver (`IkeEmails.Bank.Driver.Chrome`) for a person at a terminal:
  it opens the login page of myAlpha Web, logs in once, and tells what it saw, so that
  what the bank does can be known before anything is built on it. It is for development and
  refuses to run in production.

      mix bank.probe [--visible] [--profile DIR] [--lang CODE] [--wait SECONDS]

    * `--visible` - shows the window of the browser. It is headless without it
    * `--profile DIR` - the directory the browser keeps its profile in. Without it a new one
      is made in the temporary directory and removed at the end. A new profile is how to
      see whether the bank asks for a second factor of a browser it does not know; a profile
      that is given is kept, and so is whatever the bank made the browser remember in it
    * `--lang CODE` - the language of the browser, `en-US`. The login page of November 2026
      is in Greek whatever it is, and its field is found by the word `username`, in Latin
      letters, in its placeholder
    * `--wait SECONDS` - how long to wait after a login that worked before looking at the
      page, 15

  It asks for the user name and the password at the terminal, and does not show what is
  typed. They are never taken from an argument or from the environment, and are not printed.
  What is typed is read as UTF-8 whatever the locale of the node is, and a line that is not
  valid text is refused. Without that, a character that is not ASCII is read in the
  encoding of the locale (Latin-1 when `LANG` and `LC_ALL` are unset or `C`, as in a bare
  container or over ssh), the password that reaches the bank is another one than the one
  typed, and the login counts as a failed one. In the throwaway container of the first
  login from the server (G1), set `LANG=C.UTF-8` all the same, so that the terminal and
  the node agree.

  It has to be run from a plain shell. Inside `iex -S mix` the echo of the terminal cannot
  be turned off, and what is typed would show, so it refuses to ask there.

  ## What it prints

  The structure of the page, twice: before the login and after it. For the page it prints

    * the path of its address, without the query and the fragment
    * how many forms it has
    * for every input, button, select and link that is visible: the tag, and its `type`, `id`,
      `name`, `placeholder` and `aria-label` when it has them, a few of its classes, and
      `disabled` when it is
    * the text of the element `.login-error`, and of the messages the page shows (elements
      with `role=alert` or `aria-live`, the errors and snack bars of Angular Material),
      cut to 80 characters: the texts of the page it prints, because they are what tells
      a refused login from the rest. They are not printed after a login that worked

  It never prints the value of a field, a cookie, the local storage, the text of the page
  or an address with its query, and it takes no screenshot. It writes no file but the
  profile of the browser.

  After the login it prints how it ended, which is the result of the driver: `:ok`,
  `{:error, :bad_credentials}`, `{:error, :session_in_use}`, `{:error, :timeout}`, or one of
  `:no_login_page`, `:no_login_form` and `:no_login_button`, which mean that nothing was
  sent to the bank. When the result is `:ok` it prints the path the browser is on and logs
  out, and it logs out also when the task is stopped by an error after the login, so that
  no session of the bank is left open. A timeout means that the login was sent and that
  the bank's answer was not recognised: the page is waiting for something, or the bank
  refused it somewhere else than `.login-error`, which may count as a failed login. That is
  how a second factor (a code, a question) would show, and the structure that is printed
  then is what it is made of, to be read before a driver is written for it.

  The bank allows one session at a time, so a session of the person's own is ended by this
  login. Run it only when it is the person who runs it.
  """

  use Mix.Task

  alias IkeEmails.Bank.Credentials
  alias IkeEmails.Bank.Driver.Chrome, as: Driver

  @requirements ["app.config"]

  @switches [visible: :boolean, profile: :string, lang: :string, wait: :integer]
  @default_wait 15

  # What the page looks like, as JSON text: no value of a field, no address but its path.
  # The attributes are cut, so that a long one cannot carry much
  @structure_script """
  (() => {
    const cut = (value) => (value === null ? null : String(value).slice(0, 80));
    const shown = (element) => Boolean(element.offsetWidth || element.offsetHeight);
    const describe = (element) => ({
      tag: element.tagName.toLowerCase(),
      type: cut(element.getAttribute("type")),
      id: cut(element.getAttribute("id")),
      name: cut(element.getAttribute("name")),
      placeholder: cut(element.getAttribute("placeholder")),
      aria_label: cut(element.getAttribute("aria-label")),
      classes: [...element.classList].slice(0, 6).map(cut),
      disabled: element.disabled === true,
    });
    const error = [...document.querySelectorAll(".login-error")].find(shown);
    // Where a page of Angular Material shows an error, besides .login-error: what the
    // driver has to look at to tell a refused login, once one of them is seen
    const alerts = "[role=alert], [aria-live], mat-error, .mat-mdc-form-field-error, " +
      ".mat-mdc-snack-bar-container, mat-snack-bar-container, .login-error";
    return JSON.stringify({
      path: location.pathname,
      forms: document.forms.length,
      elements: [...document.querySelectorAll("input, button, select, a")]
        .filter(shown)
        .slice(0, 80)
        .map(describe),
      alerts: [...document.querySelectorAll(alerts)]
        .filter((element) => shown(element) && element.innerText.trim() !== "")
        .slice(0, 10)
        .map((element) => ({
          ...describe(element),
          role: cut(element.getAttribute("role")),
          text: cut(element.innerText.trim()),
        })),
      login_error: error ? cut(error.innerText.trim()) : null,
    });
  })()
  """

  @impl Mix.Task
  def run(args) do
    check_env!(Mix.env())
    opts = parse_args!(args)
    {:ok, _started} = Application.ensure_all_started(:jason)

    say("""
    This looks at the login page of myAlpha and tries one login. It prints structure only:
    tags, ids, names, placeholders, the path of the address, and the text of .login-error
    and of the messages the page shows (cut to 80 characters, and not after a login that
    worked). It prints no value, no cookie and no other text of the page, and it takes no
    screenshot.
    """)

    open_options = [
      headless: not Keyword.get(opts, :visible, false),
      user_data_dir: Keyword.get(opts, :profile),
      chrome_opts: [lang: Keyword.get(opts, :lang, "en-US")]
    ]

    case Driver.open(open_options) do
      {:ok, session} ->
        try do
          probe(session, opts)
        after
          Driver.close(session)
        end

      {:error, reason} ->
        Mix.raise("The browser could not be started: #{inspect(reason)}.")
    end
  end

  @doc false
  def structure_script, do: @structure_script

  @doc false
  def check_env!(:prod), do: Mix.raise("mix bank.probe is for development, not for production.")
  def check_env!(_env), do: :ok

  @doc false
  def parse_args!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :wait, @default_wait) < 0,
          do: Mix.raise("--wait is a number of seconds, 0 or more."),
          else: opts

      _invalid ->
        Mix.raise(
          "Usage: mix bank.probe [--visible] [--profile DIR] [--lang CODE] [--wait SECONDS]"
        )
    end
  end

  defp probe(session, opts) do
    say("The profile is #{profile(session)}.")

    say("\nBefore the login:")
    page = ok!(Driver.login_page(session), "The login page could not be opened")

    # The form is drawn by Angular, some time after the page is there. A page without it
    # is what a probe is for, so it is shown all the same
    with {:error, reason} <- Driver.await_login_form(session, page) do
      say("The login form did not show up (#{inspect(reason)}). This is what is on the page:")
    end

    show(session, page, true)

    credentials = ask_credentials()

    say("\nLogging in...")
    result = Driver.login(session, credentials)
    say("The result of the login: #{inspect(result)}")

    while_logged_in(result, fn -> log_out(session) end, fn ->
      # Only a login that worked has a page that is still changing. After a refusal the
      # page is read at once, while it still shows why
      if result == :ok do
        seconds = Keyword.get(opts, :wait, @default_wait)
        say("Waiting #{seconds} seconds.")
        Process.sleep(:timer.seconds(seconds))
      end

      say("\nAfter the login:")
      page = ok!(Driver.current_page(session), "The page is gone")
      finish(session, page, result)
    end)
  end

  @doc false
  # Runs `fun`, and after it, whatever happened to it, `logout` if the login worked: the
  # bank refuses the next login while a session is open. No logout is tried after a login
  # that failed, there is no session to end. A logout that fails is ignored, so that it
  # never takes the place of the exception of `fun`
  def while_logged_in(result, logout, fun) do
    fun.()
  after
    if result == :ok, do: ignoring_failure(logout)
  end

  defp ignoring_failure(fun) do
    _ = fun.()
    :ok
  catch
    _kind, _reason -> :ok
  end

  # Prints how the logout ended. What a failure carries is not printed
  defp log_out(session) do
    say("Logout: #{inspect(Driver.logout(session))}")
  catch
    _kind, _reason -> say("Logout: failed")
  end

  defp profile(%{remove_profile: true}), do: "a new one, removed at the end"
  defp profile(%{profile_dir: dir}), do: "#{dir}, kept"

  defp finish(session, page, :ok) do
    show(session, page, false)
    say("Logged in. The structure of the application is not listed.")
  end

  defp finish(session, page, result) do
    show(session, page, true)

    if message = outcome_message(result), do: say(message)
  end

  @doc false
  def outcome_message({:error, :timeout}) do
    """

    The login was sent, and the bank's answer was not recognised in two minutes: the page
    is waiting for something, or it refused the login somewhere else than .login-error.
    It may count as a failed login. Read what the page shows before logging in again.
    If it asks for a code or an answer, this is the second step that the driver has to learn.
    """
  end

  def outcome_message({:error, reason})
      when reason in [:no_login_page, :no_login_form, :no_login_button] do
    """

    Nothing was sent to the bank: the driver gave up before it clicked (#{reason}).
    The page has changed in a way the driver does not know. What is listed above is what
    it shows; a button that is listed with `disabled` is one that never became enabled.
    """
  end

  def outcome_message(_result), do: nil

  # Prints the page and returns what was read, or nil
  defp show(session, page, elements?) do
    case snapshot(session, page) do
      {:ok, snapshot} ->
        Enum.each(lines(snapshot, elements?), &say/1)
        snapshot

      {:error, reason} ->
        say("  The page could not be read: #{inspect(reason)}.")
        nil
    end
  end

  defp snapshot(session, page) do
    with {:ok, text} when is_binary(text) <-
           session.module.evaluate(session.chrome, page, @structure_script, []) do
      case Jason.decode(text) do
        {:ok, %{} = snapshot} -> {:ok, snapshot}
        _other -> {:error, :unexpected_response}
      end
    else
      {:error, _reason} = error -> error
      _other -> {:error, :unexpected_response}
    end
  end

  @doc false
  def lines(snapshot, elements?) do
    elements = Map.get(snapshot, "elements", [])

    [
      "  path: #{snapshot["path"]}",
      "  forms: #{snapshot["forms"]}",
      "  visible inputs, buttons, selects and links: #{length(elements)}"
    ] ++
      if(elements?, do: Enum.map(elements, &element_line/1), else: []) ++
      if(elements?, do: alert_lines(Map.get(snapshot, "alerts", [])), else: []) ++
      [error_line(snapshot["login_error"])]
  end

  # The messages the page shows, which is what tells a refused login on a page that does
  # not use .login-error. They are not listed after a login that worked, as the page of
  # the bank is no business of the probe then
  defp alert_lines([]), do: []

  defp alert_lines(alerts) do
    ["  messages shown (alerts, errors):"] ++
      for alert <- alerts do
        role = if is_binary(alert["role"]), do: " role=#{inspect(alert["role"])}", else: ""
        element_line(alert) <> role <> " text=#{inspect(alert["text"])}"
      end
  end

  defp element_line(element) do
    attributes =
      for {key, name} <- [
            {"type", "type"},
            {"id", "id"},
            {"name", "name"},
            {"placeholder", "placeholder"},
            {"aria_label", "aria-label"}
          ],
          value = element[key],
          is_binary(value) and value != "",
          do: "#{name}=#{inspect(value)}"

    classes =
      case element["classes"] do
        [_ | _] = classes -> ["class=#{inspect(Enum.join(classes, " "))}"]
        _none -> []
      end

    disabled = if element["disabled"] == true, do: ["disabled"], else: []

    "    " <> Enum.join([element["tag"] | attributes ++ classes ++ disabled], " ")
  end

  defp error_line(nil), do: "  .login-error: none is shown"

  defp error_line(text),
    do: "  .login-error: #{inspect(text)}"

  defp ok!({:ok, value}, _message), do: value
  defp ok!({:error, reason}, message), do: Mix.raise("#{message}: #{inspect(reason)}.")

  ## The credentials

  defp ask_credentials do
    say("")

    %Credentials{
      username: prompt_secret("User name (not shown): "),
      password: prompt_secret("Password (not shown): "),
      iban: ""
    }
  end

  @doc false
  # Reads a line from the terminal without showing it, see IkeEmails.Terminal
  def prompt_secret(prompt) do
    case IkeEmails.Terminal.read_secret(prompt) do
      {:ok, text} -> text
      {:error, reason} -> Mix.raise(IkeEmails.Terminal.message(reason))
    end
  end

  defp say(text), do: Mix.shell().info(String.trim_trailing(text, "\n"))
end
