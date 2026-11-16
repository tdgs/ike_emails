defmodule IkeEmails.Bank.Driver.ChromeTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Script
  alias IkeEmails.Bank.Credentials
  alias IkeEmails.Bank.Driver.Chrome, as: Driver
  alias IkeEmails.BankChromeFake, as: Fake
  alias IkeEmails.Chrome.Page
  alias IkeEmails.Chrome.Secret

  @login_url "https://secure.alpha.gr/myAlphaWeb/business/"
  @username "the-user-name"
  @password "the-pass-word-1234"
  @iban "GR0000000000000000000000000"
  @in_use "Ο λογαριασμός σας χρησιμοποιείται ήδη, ίσως από άλλον υπολογιστή."

  # What the driver waits for is short in the tests
  @fast [poll_interval: 1, login_timeout: 100, element_timeout: 100, logout_timeout: 100]

  defp credentials, do: %Credentials{username: @username, password: @password, iban: @iban}

  defp open!(opts \\ []) do
    {:ok, session} = Driver.open([chrome: Fake] ++ @fast ++ opts)

    on_exit(fn -> if session.remove_profile, do: File.rm_rf(session.profile_dir) end)
    session
  end

  defp logged_in!(opts \\ []) do
    session = open!(opts)
    :ok = Driver.login(session, credentials())
    session
  end

  defp outcome(chrome, replies), do: Fake.respond(chrome, "outcome", replies)

  defp rejection(text), do: {:ok, Jason.encode!(%{error: text})}

  defp start_opts(session), do: Agent.get(session.chrome, & &1.opts)

  describe "open/1 and close/1" do
    test "makes a profile of its own that only its user can read" do
      session = open!()

      assert String.starts_with?(session.profile_dir, Path.join(System.tmp_dir!(), "bank-"))
      assert "bank-" <> random = Path.basename(session.profile_dir)
      assert random =~ ~r/\A[0-9a-f]{16}\z/
      assert File.dir?(session.profile_dir)
      assert Bitwise.band(File.stat!(session.profile_dir).mode, 0o777) == 0o700

      opts = start_opts(session)
      assert opts[:user_data_dir] == session.profile_dir
      assert opts[:headless] == true
    end

    test "removes the profile it made, and ends the browser" do
      session = open!()
      File.write!(Path.join(session.profile_dir, "Cookies"), "what the browser wrote")

      assert Driver.close(session) == :ok

      refute File.exists?(session.profile_dir)
      assert Fake.calls(session.chrome, :stop) == [:stop]
    end

    test "does not remove a profile that is given" do
      dir = Path.join(System.tmp_dir!(), "bank-given-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(dir <> "/Cookies", "what the browser wrote")
      on_exit(fn -> File.rm_rf(dir) end)

      session = open!(user_data_dir: dir)
      assert session.profile_dir == dir
      assert Driver.close(session) == :ok

      assert File.read!(dir <> "/Cookies") == "what the browser wrote"
    end

    test "passes the options of the browser on, but not the profile or the window" do
      session =
        open!(
          headless: false,
          chrome_opts: [no_sandbox: true, lang: "el", user_data_dir: "/elsewhere", headless: true]
        )

      opts = start_opts(session)
      assert opts[:no_sandbox] == true
      assert opts[:lang] == "el"
      assert opts[:headless] == false
      assert opts[:user_data_dir] == session.profile_dir
    end

    test "gives the reason and leaves no profile behind when the browser does not start" do
      assert Driver.open(
               chrome: Fake,
               chrome_opts: [start_error: :chrome_not_found, notify: self()]
             ) == {:error, :chrome_not_found}

      assert_received {:chrome_start, opts}
      refute File.exists?(opts[:user_data_dir])
    end

    test "can be closed twice" do
      session = open!()

      assert Driver.close(session) == :ok
      assert Driver.close(session) == :ok
    end

    test "closes the page" do
      session = logged_in!()
      assert {:ok, page} = Driver.current_page(session)

      Driver.close(session)

      assert [{:close_page, ^page, _opts}] = Fake.calls(session.chrome, :close_page)
    end

    test "closes the page with the browser context it was opened in" do
      session = logged_in!()

      assert {:ok, %Page{browser_context_id: "context-" <> _} = page} =
               Driver.current_page(session)

      Driver.close(session)

      assert [{:close_page, ^page, _opts}] = Fake.calls(session.chrome, :close_page)
    end
  end

  describe "the browser context of the login page" do
    defp given_dir do
      dir = Path.join(System.tmp_dir!(), "bank-given-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    defp new_page_opts(session),
      do: for({:new_page, _page, opts} <- Fake.calls(session.chrome), do: opts)

    test "is isolated when the driver made the profile" do
      session = open!()
      assert session.isolated == true

      :ok = Driver.login(session, credentials())

      assert new_page_opts(session) == [[context: :isolated]]
      assert {:ok, %Page{browser_context_id: "context-1"}} = Driver.current_page(session)
    end

    test "is the default one when the profile is given, which is kept to be used again" do
      session = open!(user_data_dir: given_dir())
      assert session.isolated == false

      :ok = Driver.login(session, credentials())

      assert new_page_opts(session) == [[]]
      assert {:ok, %Page{browser_context_id: nil}} = Driver.current_page(session)
    end

    test "can be isolated for a profile that is given" do
      session = open!(user_data_dir: given_dir(), isolated: true)
      assert session.isolated == true

      :ok = Driver.login(session, credentials())

      assert new_page_opts(session) == [[context: :isolated]]
    end

    test "can be left the default one for a profile that the driver made" do
      session = open!(isolated: false)
      assert session.isolated == false

      :ok = Driver.login(session, credentials())

      assert new_page_opts(session) == [[]]
    end

    test "is a new one with every login, and the one before is closed with its page" do
      session = open!()
      outcome(session.chrome, [rejection(@in_use), {:ok, "{}"}])

      assert Driver.login(session, credentials()) == {:error, :session_in_use}
      assert {:ok, first} = Driver.current_page(session)
      assert Fake.calls(session.chrome, :close_page) == []

      assert Driver.login(session, credentials()) == :ok
      assert {:ok, second} = Driver.current_page(session)

      assert first.browser_context_id == "context-1"
      assert second.browser_context_id == "context-2"
      assert [{:close_page, ^first, _opts}] = Fake.calls(session.chrome, :close_page)

      Driver.close(session)

      assert [{:close_page, ^first, _}, {:close_page, ^second, _}] =
               Fake.calls(session.chrome, :close_page)
    end
  end

  describe "login/2" do
    test "opens the login page, and fills it in and submits it, in order" do
      session = open!()

      assert Driver.login(session, credentials()) == :ok

      assert [{:new_page, %Page{} = page, _opts}, {:navigate, page, @login_url, navigate_opts}] =
               Enum.take(Fake.calls(session.chrome), 2)

      assert navigate_opts[:timeout] == 30_000

      password = "input[type='password']"
      username = "input[placeholder*='username']"
      button = "form button[type='submit']:not([disabled])"

      assert [
               {"find", %{selector: ^password}},
               {"fill", %{selector: ^username, value: %Secret{} = user}},
               {"fill", %{selector: ^password, value: %Secret{} = pass}},
               {"find", %{selector: ^button}},
               {"click", %{selector: ^button}},
               {"outcome", %{}}
             ] = Fake.scripts(session.chrome)

      assert Secret.reveal(user) == @username
      assert Secret.reveal(pass) == @password
      assert {:ok, ^page} = Driver.current_page(session)
    end

    test "runs the scripts of the login page, on the page, as a user" do
      session = open!()
      :ok = Driver.login(session, credentials())

      assert [{:new_page, page, _opts} | _] = Fake.calls(session.chrome)
      source = Script.source(:login)

      for {:call_script, script_page, script, _function, _args, opts} <-
            Fake.calls(session.chrome, :call_script) do
        assert script_page == page
        assert script == source
        assert opts[:user_gesture] == true
      end
    end

    test "never gives the name or the password as a string" do
      session = open!()
      :ok = Driver.login(session, credentials())

      for {:call_script, _page, _source, _function, args, _opts} <-
            Fake.calls(session.chrome, :call_script),
          value <- Map.values(args) do
        refute value in [@username, @password]
      end

      calls = inspect(Fake.calls(session.chrome), limit: :infinity)
      refute calls =~ @username
      refute calls =~ @password
    end

    test "waits for the form until it is there" do
      session = open!()

      Fake.respond(session.chrome, "find", [
        {:ok, nil},
        {:error, :timeout},
        {:ok, %{object_id: "x"}}
      ])

      assert Driver.login(session, credentials()) == :ok

      finds = for {"find", _args} <- Fake.scripts(session.chrome), do: :find
      assert length(finds) >= 4
    end

    test "is no_login_form when the form never comes, and types nothing" do
      session = open!(element_timeout: 30)
      Fake.respond(session.chrome, "find", [{:ok, nil}])

      assert Driver.login(session, credentials()) == {:error, :no_login_form}
      refute Enum.any?(Fake.scripts(session.chrome), &match?({"fill", _args}, &1))
    end

    test "waits for the outcome while the page has none, or looks again after an error" do
      session = open!()

      outcome(session.chrome, [
        {:ok, nil},
        {:error, {:exception, %{line: 0, column: 0}}},
        {:error, :cdp_error},
        {:ok, "{}"}
      ])

      assert Driver.login(session, credentials()) == :ok

      outcomes = for {"outcome", _args} <- Fake.scripts(session.chrome), do: :outcome
      assert length(outcomes) == 4
    end

    test "is no_login_button when the button never becomes enabled, and clicks nothing" do
      session = open!(element_timeout: 30)
      # The form is there, the enabled button never is
      Fake.respond(session.chrome, "find", [{:ok, %{object_id: "form"}}, {:ok, nil}])

      assert Driver.login(session, credentials()) == {:error, :no_login_button}
      refute Enum.any?(Fake.scripts(session.chrome), &match?({"click", _args}, &1))
    end

    test "is a timeout when the bank does not answer in time" do
      session = open!(login_timeout: 30)
      outcome(session.chrome, [{:ok, nil}])

      assert Driver.login(session, credentials()) == {:error, :timeout}
    end

    test "is session_in_use when the bank says that the account is in use" do
      session = open!()
      outcome(session.chrome, [rejection(@in_use)])

      assert Driver.login(session, credentials()) == {:error, :session_in_use}
    end

    test "is bad_credentials for any other error, and the text is nowhere in the result" do
      session = open!()
      outcome(session.chrome, [rejection("Wrong password, SECRET-TEXT-OF-THE-BANK")])

      result = Driver.login(session, credentials())

      assert result == {:error, :bad_credentials}
      refute inspect(result) =~ "SECRET-TEXT"
    end

    test "looks again when the error has no text yet" do
      session = open!()
      outcome(session.chrome, [rejection(""), rejection(@in_use)])

      assert Driver.login(session, credentials()) == {:error, :session_in_use}
    end

    test "looks again at an answer that is not the one it knows" do
      session = open!()
      outcome(session.chrome, [{:ok, "not json"}, {:ok, ~s({"something":"else"})}, {:ok, "{}"}])

      assert Driver.login(session, credentials()) == :ok
    end

    test "gives up at once when the browser is gone" do
      session = open!(element_timeout: 10_000, poll_interval: 1_000)
      Fake.respond(session.chrome, "find", [{:error, :chrome_exited}])

      assert Driver.login(session, credentials()) == {:error, :chrome_exited}
    end

    test "gives up at once when the page is gone, while it waits for the outcome" do
      session = open!(login_timeout: 10_000, poll_interval: 1_000)
      outcome(session.chrome, [{:error, :page_closed}])

      assert Driver.login(session, credentials()) == {:error, :page_closed}
    end

    test "returns a script that throws as the line and the column, with no text" do
      session = open!()
      Fake.respond(session.chrome, "fill", [{:error, {:exception, %{line: 3, column: 4}}}])

      assert Driver.login(session, credentials()) == {:error, {:exception, %{line: 3, column: 4}}}
    end

    test "asks for the page to be committed, not loaded, and waits for the form after it" do
      session = open!()

      assert Driver.login(session, credentials()) == :ok

      assert [{:navigate, _page, @login_url, navigate_opts}] =
               Fake.calls(session.chrome, :navigate)

      assert navigate_opts[:wait] == :commit
      assert navigate_opts[:timeout] == 30_000

      # What is after the navigation is the wait for the form, whose time is its own
      assert [{"find", _args} | _] = Fake.scripts(session.chrome)
    end

    test "is no_login_page when the bank does not answer the request for the login page" do
      session = open!()
      Fake.respond(session.chrome, "navigate", [{:error, :timeout}])

      assert Driver.login(session, credentials()) == {:error, :no_login_page}
      assert Fake.scripts(session.chrome) == []
    end

    for reason <- [:page_closed, :chrome_exited] do
      test "gives up at once with #{reason} from the navigation" do
        session = open!()
        Fake.respond(session.chrome, "navigate", [{:error, unquote(reason)}])

        assert Driver.login(session, credentials()) == {:error, unquote(reason)}
        assert Fake.scripts(session.chrome) == []
      end
    end

    test "returns the reason when the page cannot be loaded" do
      session = open!()

      Fake.respond(session.chrome, "navigate", [
        {:error, {:navigation_failed, "net::ERR_NAME_NOT_RESOLVED"}}
      ])

      assert Driver.login(session, credentials()) ==
               {:error, {:navigation_failed, "net::ERR_NAME_NOT_RESOLVED"}}
    end

    test "starts from a fresh page every time it is called" do
      session = open!()
      outcome(session.chrome, [rejection(@in_use), {:ok, "{}"}])

      assert Driver.login(session, credentials()) == {:error, :session_in_use}
      assert {:ok, first} = Driver.current_page(session)

      assert Driver.login(session, credentials()) == :ok
      assert {:ok, second} = Driver.current_page(session)

      assert first != second

      assert [{:new_page, ^first, _}, {:new_page, ^second, _}] =
               Fake.calls(session.chrome, :new_page)

      assert [{:close_page, ^first, _}] = Fake.calls(session.chrome, :close_page)

      second_scripts =
        for {:call_script, page, _source, _function, _args, _opts} <-
              Fake.calls(session.chrome, :call_script),
            page == second,
            do: :script

      assert length(second_scripts) == 6
    end
  end

  describe "await_login_form/2" do
    test "waits until the form is there" do
      session = open!()
      {:ok, page} = Driver.login_page(session)

      Fake.respond(session.chrome, "find", [
        {:ok, nil},
        {:error, :timeout},
        {:ok, %{object_id: "x"}}
      ])

      assert Driver.await_login_form(session, page) == {:ok, :found}
    end

    test "is a timeout when the form never comes" do
      session = open!(element_timeout: 30)
      {:ok, page} = Driver.login_page(session)
      Fake.respond(session.chrome, "find", [{:ok, nil}])

      assert Driver.await_login_form(session, page) == {:error, :timeout}
    end
  end

  describe "logout/1" do
    test "clicks the logout and waits until the browser has left the app" do
      session = logged_in!()

      Fake.respond(session.chrome, "leftApp", [
        {:ok, nil},
        {:error, :cdp_error},
        {:ok, %{object_id: "b"}}
      ])

      assert Driver.logout(session) == :ok

      scripts = Fake.scripts(session.chrome)

      assert {"click", %{selector: "a.lo"}} =
               List.last(Enum.filter(scripts, &match?({"click", _}, &1)))

      assert length(Enum.filter(scripts, &match?({"leftApp", _}, &1))) == 3
    end

    test "is a timeout when the browser does not leave the app" do
      session = logged_in!(logout_timeout: 30)
      Fake.respond(session.chrome, "leftApp", [{:ok, nil}])

      assert Driver.logout(session) == {:error, :timeout}
    end

    test "does not wait when the click fails" do
      session = logged_in!()
      Fake.respond(session.chrome, "click", [{:error, {:exception, %{line: 1, column: 2}}}])

      assert Driver.logout(session) == {:error, {:exception, %{line: 1, column: 2}}}
      refute Enum.any?(Fake.scripts(session.chrome), &match?({"leftApp", _}, &1))
    end

    test "has no page before a login" do
      session = open!()

      assert Driver.logout(session) == {:error, :no_page}
    end
  end

  describe "fetch_statements/3" do
    test "returns the text of the script, which can take minutes" do
      session = logged_in!()
      Fake.respond(session.chrome, "fetch", [{:ok, ~s({"Statements": []})}])

      assert Driver.fetch_statements(session, @iban, 365) == {:ok, ~s({"Statements": []})}

      assert {:call_script, _page, source, "fetch", args, opts} =
               List.last(Fake.calls(session.chrome, :call_script))

      assert source == Script.source(:statements)
      assert args == %{iban: @iban, days: 365}
      assert opts[:await_promise] == true
      assert opts[:user_gesture] == true
      assert opts[:timeout] == 300_000
    end

    test "is no page before a login" do
      assert Driver.fetch_statements(open!(), @iban, 365) == {:error, :no_page}
    end

    test "is not a result that is not text" do
      session = logged_in!()
      Fake.respond(session.chrome, "fetch", [{:ok, %{object_id: "x"}}])

      assert Driver.fetch_statements(session, @iban, 365) == {:error, :unexpected_response}
    end

    test "returns a script that throws as the line and the column, with no text" do
      session = logged_in!()
      Fake.respond(session.chrome, "fetch", [{:error, {:exception, %{line: 7, column: 9}}}])

      assert Driver.fetch_statements(session, @iban, 365) ==
               {:error, {:exception, %{line: 7, column: 9}}}
    end
  end

  describe "fetch_details/3" do
    defp details_json(entries, failed, stopped) do
      Jason.encode!(%{entries: entries, failed: failed, stopped: stopped})
    end

    test "reads what the script returned into the entries, the failures and the stop" do
      session = logged_in!()

      reply =
        details_json(
          [%{id: "1", json: ~s({"ResultCode": 0})}, %{id: "2", json: ~s({"ResultCode": 0})}],
          1,
          nil
        )

      Fake.respond(session.chrome, "fetchDetails", [{:ok, reply}])

      assert Driver.fetch_details(session, @iban, ["1", "2", "3"]) ==
               {:ok,
                %{
                  entries: [
                    %{id: "1", json: ~s({"ResultCode": 0})},
                    %{id: "2", json: ~s({"ResultCode": 0})}
                  ],
                  failed: 1,
                  stopped: nil
                }}

      assert {:call_script, _page, source, "fetchDetails", args, opts} =
               List.last(Fake.calls(session.chrome, :call_script))

      assert source == Script.source(:statements)
      assert args == %{iban: @iban, ids: ["1", "2", "3"], concurrency: 2}
      assert opts[:await_promise] == true
      assert opts[:timeout] == 120_000
    end

    test "tells the status with which the bank refused" do
      session = logged_in!()
      Fake.respond(session.chrome, "fetchDetails", [{:ok, details_json([], 0, 403)}])

      assert {:ok, %{entries: [], failed: 0, stopped: 403}} =
               Driver.fetch_details(session, @iban, ["1"])
    end

    test "takes 20 ids at most" do
      session = logged_in!()
      ids = Enum.map(1..21, &Integer.to_string/1)
      Fake.respond(session.chrome, "fetchDetails", [{:ok, details_json([], 0, nil)}])

      assert Driver.fetch_details(session, @iban, ids) == {:error, :too_many_ids}
      assert {:ok, _details} = Driver.fetch_details(session, @iban, Enum.take(ids, 20))
    end

    for {name, reply} <- [
          {"text that is not JSON", "not json"},
          {"no entries", ~s({"failed": 0, "stopped": null})},
          {"an entry without a text",
           ~s({"entries": [{"id": "1"}], "failed": 0, "stopped": null})},
          {"a failure count that is not a count",
           ~s({"entries": [], "failed": -1, "stopped": null})},
          {"a stop that is not a refusal", ~s({"entries": [], "failed": 0, "stopped": 500})}
        ] do
      test "is not understood with #{name}" do
        session = logged_in!()
        Fake.respond(session.chrome, "fetchDetails", [{:ok, unquote(reply)}])

        assert Driver.fetch_details(session, @iban, ["1"]) == {:error, :unexpected_response}
      end
    end
  end

  describe "list_estatements/2 and fetch_estatement/2" do
    test "returns the list as the text of the script" do
      session = logged_in!()
      Fake.respond(session.chrome, "listEStatements", [{:ok, ~s({"EStatements": []})}])

      assert Driver.list_estatements(session, @iban) == {:ok, ~s({"EStatements": []})}

      assert {:call_script, _page, _source, "listEStatements", %{iban: @iban}, opts} =
               List.last(Fake.calls(session.chrome, :call_script))

      assert opts[:await_promise] == true
    end

    test "reads the size and the content of the PDF" do
      session = logged_in!()

      Fake.respond(session.chrome, "fetchEStatement", [
        {:ok, Jason.encode!(%{bytes: 9, base64: "JVBERi0xLjQ="})}
      ])

      assert Driver.fetch_estatement(session, "abc") ==
               {:ok, %{bytes: 9, base64: "JVBERi0xLjQ="}}

      assert {:call_script, _page, _source, "fetchEStatement", %{id: "abc"}, opts} =
               List.last(Fake.calls(session.chrome, :call_script))

      assert opts[:timeout] == 120_000
    end

    test "does not understand a PDF without a size" do
      session = logged_in!()
      Fake.respond(session.chrome, "fetchEStatement", [{:ok, ~s({"base64": "abc"})}])

      assert Driver.fetch_estatement(session, "abc") == {:error, :unexpected_response}
    end
  end

  describe "the console of the page" do
    defp console(args) do
      %{"type" => "log", "args" => Enum.map(args, &%{"type" => "string", "value" => &1})}
    end

    defp relay_to_test do
      test = self()
      fn line -> send(test, {:console, line}) end
    end

    test "passes on the progress lines of the scripts" do
      session = open!(on_console: relay_to_test())

      Fake.emit(
        session.chrome,
        "Runtime.consoleAPICalled",
        console(["[crawler]", "#1", "request", "details of 42"])
      )

      Fake.emit(
        session.chrome,
        "Runtime.consoleAPICalled",
        console(["[crawler]", "#1", "done in", "812 ms"])
      )

      assert_receive {:console, "#1 request details of 42"}
      assert_receive {:console, "#1 done in 812 ms"}
    end

    test "drops the failures, which carry what the bank answered" do
      session = open!(on_console: relay_to_test())
      event = "Runtime.consoleAPICalled"

      Fake.emit(
        session.chrome,
        event,
        console(["[crawler]", "#2", "failed in", "5 ms", "HTTP 500: {...}"])
      )

      Fake.emit(session.chrome, event, console(["[crawler]", "failed in 5 ms HTTP 500"]))
      # A failure that says the words of a progress line
      Fake.emit(
        session.chrome,
        event,
        console(["[crawler]", "#2", "failed in", "5 ms", "done in"])
      )

      Fake.emit(session.chrome, event, console(["[crawler]", "#3", "request", "after"]))

      assert_receive {:console, "#3 request after"}
      refute_received {:console, _line}
    end

    test "reads only the messages whose first argument is the tag" do
      session = open!(on_console: relay_to_test())
      event = "Runtime.consoleAPICalled"

      Fake.emit(session.chrome, event, console(["request", "of the application"]))
      Fake.emit(session.chrome, event, console(["", "[crawler]", "#1", "request", "x"]))
      Fake.emit(session.chrome, event, console(["[crawler] #1 request x"]))
      Fake.emit(session.chrome, event, %{"type" => "log", "args" => []})
      Fake.emit(session.chrome, event, %{"type" => "log"})

      objects = [
        %{"type" => "string", "value" => "[crawler]"},
        %{"type" => "object", "description" => "Object"}
      ]

      Fake.emit(session.chrome, event, %{"type" => "log", "args" => objects})

      Fake.emit(
        session.chrome,
        "Page.frameNavigated",
        console(["[crawler]", "#1", "request", "x"])
      )

      Fake.emit(session.chrome, event, console(["[crawler]", "#9", "request", "last"]))

      assert_receive {:console, "#9 request last"}
      refute_received {:console, _line}
    end

    test "is not stopped by a function that raises" do
      test = self()

      relay = fn line ->
        if line =~ "first", do: raise("boom"), else: send(test, {:console, line})
      end

      session = open!(on_console: relay)
      event = "Runtime.consoleAPICalled"

      Fake.emit(session.chrome, event, console(["[crawler]", "#1", "request", "first"]))
      Fake.emit(session.chrome, event, console(["[crawler]", "#2", "request", "second"]))

      assert_receive {:console, "#2 request second"}
    end

    test "is not read at all without a function" do
      session = open!()

      assert session.relay == nil
      assert Fake.calls(session.chrome, :subscribe) == []
    end

    test "ends with the session" do
      session = open!(on_console: relay_to_test())
      monitor = Process.monitor(session.relay)

      Driver.close(session)

      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    end
  end
end
