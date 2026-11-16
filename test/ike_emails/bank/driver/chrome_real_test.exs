defmodule IkeEmails.Bank.Driver.ChromeRealTest do
  @moduledoc """
  The driver with a real Chrome, on a page of this machine that stands in for the bank
  (`IkeEmails.BankLoginPage`); nothing here goes to the network.

      mix test --include chrome test/ike_emails/bank/driver/chrome_real_test.exs

  Chrome is the one of `CHROME_PATH`, or the first on the `PATH`, or the Chrome of macOS.
  `CHROME_NO_SANDBOX=1` runs it without its sandbox, which a container as root needs.
  """

  use ExUnit.Case, async: false

  alias IkeEmails.Bank.Alpha.Details
  alias IkeEmails.Bank.Alpha.EStatements
  alias IkeEmails.Bank.Alpha.Pdf
  alias IkeEmails.Bank.Alpha.Statements
  alias IkeEmails.Bank.Credentials
  alias IkeEmails.Bank.Driver.Chrome, as: Driver
  alias IkeEmails.BankLoginPage
  alias IkeEmails.Chrome.Secret
  alias Mix.Tasks.Bank.Probe

  @moduletag :chrome
  @moduletag timeout: 120_000

  @iban "GR0000000000000000000000000"
  # Typed in the login page, and looked for in the profile of the browser afterwards
  @user "sentinel-user-name-7f3a9c"

  setup_all do
    {server, url} = BankLoginPage.start()

    %{server: server, url: url}
  end

  defp credentials(username \\ "someone", password \\ "right-password") do
    %Credentials{username: username, password: password, iban: @iban}
  end

  defp base_options(url) do
    [
      login_url: url <> "myAlphaWeb/business/auth/login",
      chrome_opts: [no_sandbox: System.get_env("CHROME_NO_SANDBOX") == "1"],
      poll_interval: 100,
      login_timeout: 20_000,
      element_timeout: 20_000,
      logout_timeout: 20_000
    ]
  end

  # The session is closed whatever the test does
  defp with_session(url, opts \\ [], fun) do
    {:ok, session} = Driver.open(Keyword.merge(base_options(url), opts))

    try do
      fun.(session)
    after
      Driver.close(session)
    end
  end

  describe "a session" do
    test "logs in, reads what the application has, and logs out", %{url: url} do
      with_session(url, fn session ->
        assert Driver.login(session, credentials()) == :ok

        assert {:ok, statements} = Driver.fetch_statements(session, @iban, 30)
        assert {:ok, %{statements: [], new_balance: balance}} = Statements.parse(statements)
        assert Decimal.equal?(balance, 10)

        assert {:ok, %{entries: entries, failed: 0, stopped: nil}} =
                 Driver.fetch_details(session, @iban, ["1", "2", "3"])

        assert entries |> Enum.map(& &1.id) |> Enum.sort() == ["1", "2", "3"]
        assert {:ok, details} = Details.parse(Map.new(entries, &{&1.id, &1.json}))
        assert details["2"].sender_details == "sender 2"

        assert {:ok, list} = Driver.list_estatements(session, @iban)
        assert {:ok, [_ | _] = estatements} = EStatements.parse(list)
        assert {:ok, estatement} = EStatements.latest(estatements)
        assert {:ok, pdf} = Driver.fetch_estatement(session, estatement.id)
        assert Pdf.decode(pdf) == {:ok, BankLoginPage.pdf()}

        assert Driver.logout(session) == :ok
      end)
    end

    test "refuses a wrong password", %{url: url} do
      with_session(url, fn session ->
        assert Driver.login(session, credentials("someone", "wrong")) ==
                 {:error, :bad_credentials}
      end)
    end

    test "tells that the account is in use", %{url: url} do
      with_session(url, fn session ->
        assert Driver.login(session, credentials("in-use")) == {:error, :session_in_use}
      end)
    end

    test "is a timeout when the page does not decide", %{url: url} do
      with_session(url, [login_timeout: 1_500], fn session ->
        assert Driver.login(session, credentials("stuck")) == {:error, :timeout}
      end)
    end

    test "logs in again from a fresh page after a refusal", %{url: url} do
      with_session(url, fn session ->
        assert Driver.login(session, credentials("someone", "wrong")) ==
                 {:error, :bad_credentials}

        {:ok, first} = Driver.current_page(session)

        assert Driver.login(session, credentials()) == :ok
        {:ok, second} = Driver.current_page(session)

        assert first != second
        assert Driver.logout(session) == :ok
      end)
    end

    test "has no page, and nothing to fetch, before a login", %{url: url} do
      with_session(url, fn session ->
        assert Driver.fetch_statements(session, @iban, 30) == {:error, :no_page}
        assert Driver.logout(session) == {:error, :no_page}
      end)
    end

    test "counts the details that the bank did not give, and stops at a refusal", %{url: url} do
      with_session(url, fn session ->
        :ok = Driver.login(session, credentials())

        assert {:ok, %{entries: [%{id: "1"}], failed: 1, stopped: nil}} =
                 Driver.fetch_details(session, @iban, ["1", "bad"])

        assert {:ok, %{stopped: 403}} = Driver.fetch_details(session, @iban, ["refused", "1"])
      end)
    end

    test "removes the profile it made, and keeps the one that is given", %{url: url} do
      given = Path.join(System.tmp_dir!(), "bank-real-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(given) end)

      made = with_session(url, fn session -> session.profile_dir end)
      refute File.exists?(made)

      with_session(url, [user_data_dir: given], fn session ->
        :ok = Driver.login(session, credentials())
      end)

      assert File.dir?(given)
    end
  end

  describe "a login page that does not finish loading" do
    test "logs in although an image of the page never comes", %{url: url} do
      login_url = url <> "myAlphaWeb/business/auth/login?hang"

      with_session(url, [login_url: login_url], fn session ->
        {:ok, page} = Driver.login_page(session)
        {:ok, state} = session.module.evaluate(session.chrome, page, "document.readyState")
        # The page has its form, and the image holds the load back for minutes
        assert state in ["loading", "interactive"]

        # Waiting for it to load, as the login did, ends in the timeout
        assert session.module.navigate(session.chrome, page, login_url, timeout: 1_500) ==
                 {:error, :timeout}

        {microseconds, result} = :timer.tc(fn -> Driver.login(session, credentials()) end)

        assert result == :ok
        # The wait for the page to load was 30 seconds, and ended in a timeout
        assert microseconds < 15_000_000
        assert Driver.logout(session) == :ok
      end)
    end

    test "logs in from a page that replaces itself while it is read", %{url: url} do
      login_url = url <> "myAlphaWeb/business/auth/entry"

      with_session(url, [login_url: login_url], fn session ->
        {:ok, page} = Driver.login_page(session)

        # The load of the first document never comes, so waiting for it ends in the timeout
        assert session.module.navigate(session.chrome, page, login_url, timeout: 1_500) ==
                 {:error, :timeout}

        assert Driver.login(session, credentials()) == :ok
        assert Driver.logout(session) == :ok
      end)
    end

    test "is a failure of the navigation when the bank cannot be reached", %{url: url} do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      with_session(url, [login_url: "http://127.0.0.1:#{port}/"], fn session ->
        assert Driver.login(session, credentials()) ==
                 {:error, {:navigation_failed, "net::ERR_CONNECTION_REFUSED"}}
      end)
    end
  end

  describe "what Chrome writes to the disk" do
    # The files of the profile that have the text in them, whatever they are
    defp stored(dir, text) do
      {output, _status} = System.cmd("grep", ["-rlaF", "--", text, dir], stderr_to_stdout: true)

      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "grep:"))
    end

    # Chrome of this profile, and its helpers, which no other Chrome of the machine has
    defp running?(dir) do
      {_output, status} = System.cmd("pgrep", ["-f", "--", "--user-data-dir=" <> dir])
      status == 0
    end

    defp gone?(dir, tries \\ 100) do
      cond do
        not running?(dir) -> true
        tries == 0 -> false
        true -> Process.sleep(100) && gone?(dir, tries - 1)
      end
    end

    # A node that is killed after the login: the browser ends, the profile does not
    defp login_and_kill(url, opts) do
      test = self()

      owner =
        spawn(fn ->
          {:ok, session} = Driver.open(Keyword.merge(base_options(url), opts))
          :ok = Driver.login(session, credentials(@user))
          send(test, {:logged_in, session.profile_dir})
          Process.sleep(:infinity)
        end)

      assert_receive {:logged_in, dir}, 60_000
      on_exit(fn -> File.rm_rf(dir) end)
      assert running?(dir)

      Process.exit(owner, :kill)

      assert gone?(dir), "Chrome is still running after its owner was killed"
      dir
    end

    @tag :capture_log
    test "keeps neither the user name nor the local storage in the profile that the driver made",
         %{url: url} do
      # While it runs, and after it is killed, which leaves the profile where it is
      dir = login_and_kill(url, [])

      assert File.dir?(dir)
      assert stored(dir, @user) == []
      assert stored(dir, BankLoginPage.stored_value()) == []
    end

    @tag :capture_log
    test "keeps them in the profile that the driver made, when it is not isolated", %{url: url} do
      dir = login_and_kill(url, isolated: false)

      assert stored(dir, @user) != []
      assert stored(dir, BankLoginPage.stored_value()) != []
    end

    test "keeps them in a profile that is given, which is the point of it", %{url: url} do
      given = Path.join(System.tmp_dir!(), "bank-real-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(given) end)

      with_session(url, [user_data_dir: given], fn session ->
        assert session.isolated == false
        :ok = Driver.login(session, credentials(@user))
      end)

      assert stored(given, @user) != []
      assert stored(given, BankLoginPage.stored_value()) != []
    end

    test "keeps neither in a profile that is given, when it is isolated", %{url: url} do
      given = Path.join(System.tmp_dir!(), "bank-real-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(given) end)

      with_session(url, [user_data_dir: given, isolated: true], fn session ->
        :ok = Driver.login(session, credentials(@user))
      end)

      assert File.dir?(given)
      assert stored(given, @user) == []
      assert stored(given, BankLoginPage.stored_value()) == []
    end
  end

  describe "the console of the page" do
    test "passes on the progress lines, and not the failures", %{url: url} do
      test = self()

      with_session(url, [on_console: fn line -> send(test, {:console, line}) end], fn session ->
        :ok = Driver.login(session, credentials())
        {:ok, _details} = Driver.fetch_details(session, @iban, ["1", "bad"])

        lines = console_lines()

        # The calls run two at a time, so the order is not fixed
        assert Enum.count(lines, &(&1 =~ ~r/\A#\d+ request details of 1\z/)) == 1
        assert Enum.count(lines, &(&1 =~ ~r/\A#\d+ request details of bad\z/)) == 1
        assert Enum.count(lines, &(&1 =~ ~r/\A#\d+ done in \d+ ms\z/)) == 1
        # The failure said what the bank answered
        assert length(lines) == 3
      end)
    end
  end

  defp console_lines(lines \\ []) do
    receive do
      {:console, line} -> console_lines([line | lines])
    after
      1_000 -> Enum.reverse(lines)
    end
  end

  describe "the structure that mix bank.probe prints" do
    test "is the structure of the page, and no value, query or fragment", %{url: url} do
      with_session(url, fn session ->
        address = session.login_url <> "?token=query-secret#fragment-secret"
        {:ok, page} = Driver.login_page(session)
        {:ok, _loaded} = session.module.navigate(session.chrome, page, address)

        typed = "typed-secret-value"
        script = ~s|document.querySelector("#user").value = "#{typed}"|
        {:ok, _typed} = session.module.evaluate(session.chrome, page, script)

        {:ok, text} = session.module.evaluate(session.chrome, page, Probe.structure_script())
        refute text =~ typed
        refute text =~ "query-secret"
        refute text =~ "fragment-secret"

        snapshot = Jason.decode!(text)
        assert snapshot["path"] == "/myAlphaWeb/business/auth/login"
        assert snapshot["forms"] == 2
        assert snapshot["login_error"] == nil

        ids = for element <- snapshot["elements"], do: element["id"]
        assert "user" in ids and "pass" in ids
        # The first form is hidden
        refute "hidden-user" in ids

        user = Enum.find(snapshot["elements"], &(&1["id"] == "user"))
        assert user["tag"] == "input"
        assert user["type"] == "text"
        assert user["placeholder"] == "Enter your username"
        assert user["classes"] == ["form-control"]

        lines = Probe.lines(snapshot, true)
        assert Enum.any?(lines, &(&1 =~ ~s|input type="text" id="user"|))
        refute Enum.any?(lines, &(&1 =~ typed))
      end)
    end

    test "shows the text of the error of the login page, among the messages too", %{
      url: url
    } do
      with_session(url, fn session ->
        {:ok, page} = Driver.login_page(session)
        source = IkeEmails.Bank.Alpha.Script.source(:login)
        call = &session.module.call_script(session.chrome, page, source, &1, &2, [])

        {:ok, _} =
          call.("fill", %{selector: "input[placeholder*='username']", value: Secret.new("x")})

        {:ok, _} =
          call.("fill", %{selector: "input[type='password']", value: Secret.new("wrong")})

        {:ok, _} = call.("click", %{selector: "form button[type='submit']:not([disabled])"})

        {:ok, text} = session.module.evaluate(session.chrome, page, Probe.structure_script())

        snapshot = Jason.decode!(text)
        assert snapshot["login_error"] == "The user name or the password is wrong"

        assert [%{"tag" => "div", "classes" => ["login-error"], "text" => text}] =
                 snapshot["alerts"]

        assert text == "The user name or the password is wrong"
      end)
    end
  end
end
