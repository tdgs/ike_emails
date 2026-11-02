defmodule IkeEmails.Elorus.ConnectionTest do
  # Not async: the requests are made by the process of the connection, so the
  # stubs of Req.Test are shared, and some tests change the idle timeout
  use IkeEmails.DataCase, async: false

  import ExUnit.CaptureLog
  import IkeEmails.Fixtures

  alias IkeEmails.Elorus.Connection
  alias IkeEmails.Elorus.Credentials
  alias IkeEmails.Elorus.Locks
  alias IkeEmails.ElorusStub
  alias IkeEmails.Settings
  alias IkeEmails.Settings.UserSettings

  setup {Req.Test, :set_req_test_to_shared}
  setup :create_user_scope

  setup %{scope: scope} do
    original = Application.get_env(:ike_emails, Connection)

    on_exit(fn ->
      Application.put_env(:ike_emails, Connection, original)
      Connection.lock(scope)
    end)

    :ok
  end

  defp put_idle_timeout(milliseconds) do
    Application.put_env(:ike_emails, Connection, idle_timeout: milliseconds)
  end

  defp pid_of(scope) do
    assert [{pid, _}] = Registry.lookup(IkeEmails.Elorus.Registry, scope.user.id)
    pid
  end

  defp wait_until_locked(scope, tries \\ 500) do
    cond do
      not Connection.unlocked?(scope) -> :ok
      tries == 0 -> flunk("the credentials were not locked")
      true -> Process.sleep(10) && wait_until_locked(scope, tries - 1)
    end
  end

  # The message of a call that waits for the process, which is busy
  defp wait_until_queued(pid, tries \\ 500) do
    cond do
      Process.info(pid, :message_queue_len) == {:message_queue_len, 1} -> :ok
      tries == 0 -> flunk("no call is waiting for the process")
      true -> Process.sleep(10) && wait_until_queued(pid, tries - 1)
    end
  end

  describe "without a process" do
    test "everything is locked", %{scope: scope} do
      Req.Test.stub(IkeEmails.Elorus, fn _conn -> flunk("no request should be made") end)

      refute Connection.unlocked?(scope)
      assert Connection.list_all_invoices(scope) == {:error, :locked}

      assert Connection.list_all_invoices(scope, [period: "last_month"], max_pages: 1) ==
               {:error, :locked}

      assert Connection.invoice_pdf(scope, "123") == {:error, :locked}
      assert Connection.lock(scope) == :ok
    end
  end

  describe "put_credentials/2, unlocked?/1 and lock/1" do
    test "unlock, and lock again", %{scope: scope} do
      assert :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
      assert Connection.unlocked?(scope)

      assert Connection.lock(scope) == :ok
      refute Connection.unlocked?(scope)
      assert Connection.list_all_invoices(scope) == {:error, :locked}
    end

    test "put other credentials in place of the ones there were", %{scope: scope} do
      ElorusStub.stub()

      Connection.put_credentials(
        scope,
        elorus_credentials_fixture(api_token: "first-token-12345")
      )

      Connection.put_credentials(
        scope,
        elorus_credentials_fixture(api_token: "second-token-6789")
      )

      assert {:ok, []} = Connection.list_all_invoices(scope)
      assert %{"authorization" => "Token second-token-6789"} = ElorusStub.last_headers()
    end

    test "there is one process for a user", %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture())
      pid = pid_of(scope)

      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert pid_of(scope) == pid
    end

    test "can be unlocked again after it was locked", %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture())
      Connection.lock(scope)

      assert :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
      assert Connection.unlocked?(scope)
    end
  end

  describe "unlock/2" do
    test "opens the key of the user with their password", %{scope: scope} do
      settings_fixture(scope, %{elorus_demo: "true"})
      ElorusStub.stub()

      assert Connection.unlock(scope, valid_user_password()) == :ok
      assert Connection.unlocked?(scope)

      assert {:ok, []} = Connection.list_all_invoices(scope)

      assert %{
               "authorization" => "Token test-elorus-token",
               "x-elorus-organization" => "1000000243015421",
               "x-elorus-demo" => "true"
             } = ElorusStub.last_headers()
    end

    test "is refused for a wrong password, and stays locked", %{scope: scope} do
      settings_fixture(scope)

      assert Connection.unlock(scope, "not the password") == {:error, :invalid_password}
      refute Connection.unlocked?(scope)
    end

    test "is refused without an API key", %{scope: scope} do
      assert Connection.unlock(scope, valid_user_password()) == {:error, :not_configured}

      settings_fixture(scope, %{}, token: nil)
      assert Connection.unlock(scope, valid_user_password()) == {:error, :not_configured}
      refute Connection.unlocked?(scope)
    end

    test "is refused for a key that does not open", %{scope: scope} do
      settings_fixture(scope)
      Repo.update_all(UserSettings, set: [elorus_token_sealed: "1.XCP.AAAAAAAAAAAAAAAAAAAAAA"])

      assert Connection.unlock(scope, valid_user_password()) == {:error, :undecryptable}
      refute Connection.unlocked?(scope)
    end

    test "leaves what was unlocked as it was when it is refused", %{scope: scope} do
      settings_fixture(scope)
      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert Connection.unlock(scope, "not the password") == {:error, :invalid_password}

      assert Connection.unlocked?(scope)
    end
  end

  describe "a lock while the key is being opened" do
    # What `unlock/2` does: it reads the epoch before it opens the key (which takes a
    # while), and hands the credentials over when it is done

    test "refuses the credentials, when there was nothing to end", %{scope: scope} do
      epoch = Locks.epoch(scope.user.id)

      assert Connection.lock(scope) == :ok

      assert Connection.put_credentials(scope, elorus_credentials_fixture(), epoch) ==
               {:error, :locked}

      # Not even a process was started for them
      refute Connection.unlocked?(scope)
      assert Connection.list_all_invoices(scope) == {:error, :locked}
    end

    test "refuses the credentials, when there was a process to end", %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture())
      epoch = Locks.epoch(scope.user.id)

      Connection.lock(scope)

      assert Connection.put_credentials(scope, elorus_credentials_fixture(), epoch) ==
               {:error, :locked}

      refute Connection.unlocked?(scope)
    end

    test "does not refuse the credentials of an unlock that began after it", %{scope: scope} do
      Connection.lock(scope)
      epoch = Locks.epoch(scope.user.id)

      assert Connection.put_credentials(scope, elorus_credentials_fixture(), epoch) == :ok
      assert Connection.unlocked?(scope)
    end

    test "does not refuse the credentials of the other users", %{scope: scope} do
      other = user_scope_fixture()
      epoch = Locks.epoch(other.user.id)

      Connection.lock(scope)

      assert Connection.put_credentials(other, elorus_credentials_fixture(), epoch) == :ok
      Connection.lock(other)
    end

    test "refuses the credentials that wait for the process, which is busy", %{scope: scope} do
      test = self()

      Req.Test.stub(IkeEmails.Elorus, fn conn ->
        send(test, :request_started)
        Process.sleep(:infinity)
        conn
      end)

      Connection.put_credentials(scope, elorus_credentials_fixture())
      pid = pid_of(scope)
      request = Task.async(fn -> Connection.list_all_invoices(scope) end)
      assert_receive :request_started, 2_000

      epoch = Locks.epoch(scope.user.id)

      unlock =
        Task.async(fn ->
          Connection.put_credentials(scope, elorus_credentials_fixture(), epoch)
        end)

      wait_until_queued(pid)

      assert Connection.lock(scope) == :ok

      # They are not put in another process that is started in its place
      assert Task.await(unlock) == {:error, :locked}
      assert Task.await(request) == {:error, :locked}
      refute Connection.unlocked?(scope)
    end

    test "refuses the credentials when the lock comes after the check of the epoch", %{
      scope: scope
    } do
      # The lock is counted, and has not ended the process yet. The credentials that are
      # in the process stay, as they are from an unlock after the lock
      ElorusStub.stub()

      Connection.put_credentials(
        scope,
        elorus_credentials_fixture(api_token: "first-token-12345")
      )

      pid = pid_of(scope)
      epoch = Locks.epoch(scope.user.id)
      Locks.bump(scope.user.id)

      message =
        {:put_credentials, elorus_credentials_fixture(api_token: "second-token-6789"), epoch}

      assert GenServer.call(pid, message) == {:error, :locked}

      assert {:ok, []} = Connection.list_all_invoices(scope)
      assert %{"authorization" => "Token first-token-12345"} = ElorusStub.last_headers()
    end

    test "ends a process that has no credentials to keep", %{scope: scope} do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          IkeEmails.Elorus.ConnectionSupervisor,
          {Connection, scope.user.id}
        )

      ref = Process.monitor(pid)
      epoch = Locks.epoch(scope.user.id)
      Locks.bump(scope.user.id)

      message = {:put_credentials, elorus_credentials_fixture(), epoch}
      assert GenServer.call(pid, message) == {:error, :locked}

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "the requests" do
    test "are made with the credentials of the user", %{scope: scope} do
      ElorusStub.stub(invoices: [ElorusStub.invoice_json()], pdfs: %{"7" => "%PDF-1.4 seven"})

      Connection.put_credentials(
        scope,
        elorus_credentials_fixture(api_token: "my-token-12345", organization_id: "55", demo: true)
      )

      assert {:ok, [%{id: "1050000300010040"}]} =
               Connection.list_all_invoices(scope, period: "last_month")

      assert {:ok, "%PDF-1.4 seven"} = Connection.invoice_pdf(scope, "7")

      assert [list, pdf] = ElorusStub.request_headers()

      for headers <- [list, pdf] do
        assert %{
                 "authorization" => "Token my-token-12345",
                 "x-elorus-organization" => "55",
                 "x-elorus-demo" => "true"
               } = headers
      end
    end

    test "are made by the process of the connection, one at a time", %{scope: scope} do
      test = self()

      Req.Test.stub(IkeEmails.Elorus, fn conn ->
        send(test, {:request_from, self()})
        Req.Test.json(conn, %{"count" => 0, "next" => nil, "previous" => nil, "results" => []})
      end)

      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert {:ok, []} = Connection.list_all_invoices(scope)

      pid = pid_of(scope)
      assert_received {:request_from, ^pid}
    end

    test "return the errors of Elorus, and stay unlocked", %{scope: scope} do
      ElorusStub.stub(status: 401)
      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert Connection.list_all_invoices(scope) == {:error, :unauthorized}
      assert Connection.invoice_pdf(scope, "1") == {:error, :unauthorized}
      assert Connection.invoice_pdf(scope, "../1") == {:error, :invalid_id}
      assert Connection.unlocked?(scope)
    end

    test "of a user have the credentials of that user", %{scope: scope} do
      other = user_scope_fixture()
      ElorusStub.stub()

      Connection.put_credentials(scope, elorus_credentials_fixture(api_token: "token-of-mine-1"))

      Connection.put_credentials(
        other,
        elorus_credentials_fixture(api_token: "token-of-theirs", organization_id: "999")
      )

      assert {:ok, []} = Connection.list_all_invoices(scope)
      assert {:ok, []} = Connection.list_all_invoices(other)
      assert {:ok, []} = Connection.list_all_invoices(scope)

      assert [mine, theirs, mine_again] = ElorusStub.request_headers()
      assert mine["authorization"] == "Token token-of-mine-1"
      assert mine["x-elorus-organization"] == "1000000243015421"
      assert theirs["authorization"] == "Token token-of-theirs"
      assert theirs["x-elorus-organization"] == "999"
      assert mine_again == mine

      assert pid_of(scope) != pid_of(other)

      Connection.lock(other)
    end

    test "of a user who locked make no request, and the others are not locked", %{scope: scope} do
      other = user_scope_fixture()
      ElorusStub.stub()
      Connection.put_credentials(scope, elorus_credentials_fixture())
      Connection.put_credentials(other, elorus_credentials_fixture())

      Connection.lock(scope)

      assert Connection.list_all_invoices(scope) == {:error, :locked}
      assert Connection.unlocked?(other)
      assert {:ok, []} = Connection.list_all_invoices(other)
      assert length(ElorusStub.request_paths()) == 1

      Connection.lock(other)
    end

    test "are cut short when it is locked meanwhile", %{scope: scope} do
      test = self()

      Req.Test.stub(IkeEmails.Elorus, fn conn ->
        send(test, :request_started)
        Process.sleep(:infinity)
        conn
      end)

      Connection.put_credentials(scope, elorus_credentials_fixture())
      task = Task.async(fn -> Connection.list_all_invoices(scope) end)
      assert_receive :request_started, 2_000

      log = capture_log(fn -> assert Connection.lock(scope) == :ok end)

      assert Task.await(task) == {:error, :locked}
      refute Connection.unlocked?(scope)
      # Not a crash
      assert log == ""
    end
  end

  describe "the idle timeout" do
    # The end of the window is a message, `:timeout`, which is sent by the tests that
    # are not about the timer. The ones that are start it with a window that is not the
    # one of the process, which is long, so that what they wait for is the end of it,
    # and they do not race it

    test "locks it when it was not used", %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture())
      pid = pid_of(scope)
      ref = Process.monitor(pid)

      send(pid, :timeout)

      # It ends normally: it is not a crash
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      refute Connection.unlocked?(scope)
      assert Connection.list_all_invoices(scope) == {:error, :locked}
    end

    test "starts with the process, which ends when it got no credentials", %{scope: scope} do
      put_idle_timeout(50)

      # Started and monitored in one step, as a window that is short could end first
      {:ok, {pid, ref}} = :gen_server.start_monitor(Connection, scope.user.id, [])

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "starts with every unlock", %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture())
      pid = pid_of(scope)
      ref = Process.monitor(pid)

      put_idle_timeout(50)
      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "starts with every request", %{scope: scope} do
      ElorusStub.stub()
      Connection.put_credentials(scope, elorus_credentials_fixture())
      pid = pid_of(scope)
      ref = Process.monitor(pid)

      put_idle_timeout(50)
      assert {:ok, []} = Connection.list_all_invoices(scope)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "is started again by every call, and by every unlock", %{scope: scope} do
      put_idle_timeout(2_000)
      ElorusStub.stub()
      Connection.put_credentials(scope, elorus_credentials_fixture())
      pid = pid_of(scope)

      # 2.4 seconds in all, which is more than the window
      Process.sleep(1_200)
      assert {:ok, []} = Connection.list_all_invoices(scope)
      Process.sleep(1_200)
      assert :ok = Connection.put_credentials(scope, elorus_credentials_fixture())

      assert Connection.unlocked?(scope)
      assert pid_of(scope) == pid
    end

    test "is not started again by asking whether it is unlocked", %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture())
      pid = pid_of(scope)
      ref = Process.monitor(pid)

      put_idle_timeout(100)
      Connection.put_credentials(scope, elorus_credentials_fixture())

      # It is asked more often than the window lasts: if that started it again, it
      # would never end
      wait_until_locked(scope)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "locks a user and not the others", %{scope: scope} do
      other = user_scope_fixture()
      Connection.put_credentials(scope, elorus_credentials_fixture())
      Connection.put_credentials(other, elorus_credentials_fixture())
      pid = pid_of(scope)
      ref = Process.monitor(pid)

      send(pid, :timeout)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      refute Connection.unlocked?(scope)
      assert Connection.unlocked?(other)

      Connection.lock(other)
    end
  end

  describe "the API key" do
    @token "a-secret-api-key-123456"

    setup %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture(api_token: @token))
      %{pid: pid_of(scope)}
    end

    # The whole term, not what is shown of it: the credentials do not show their API key
    # when they are inspected
    test "is not in the state, the status, or what looks into the process", %{pid: pid} do
      # The check finds it where it is
      assert :erlang.term_to_binary(%Credentials{api_token: @token}) =~ @token

      for term <- [:sys.get_state(pid), :sys.get_status(pid), Process.info(pid)] do
        refute :erlang.term_to_binary(term) =~ @token
      end
    end

    test "is in a table that only the process can read", %{pid: pid} do
      assert %{credentials: table} = :sys.get_state(pid)

      assert_raise ArgumentError, fn -> :ets.tab2list(table) end
      assert_raise ArgumentError, fn -> :ets.lookup(table, :credentials) end
    end

    test "is out of reach of what looks into a process", %{pid: pid} do
      assert Process.info(pid, :dictionary) == {:dictionary, []}
      assert Process.info(pid, :messages) == {:messages, []}

      # Tracing is on, and no message of the process is traced
      assert :erlang.trace(pid, true, [:receive, :send]) == 1
      send(pid, :anything)
      refute_receive {:trace, ^pid, _, _}, 100
      refute_receive {:trace, ^pid, _, _, _}, 100
      :erlang.trace(pid, false, [:receive, :send])
    end

    test "is not in the credentials when they are inspected" do
      credentials = elorus_credentials_fixture(api_token: @token)

      refute inspect(credentials) =~ @token
      refute inspect({:put_credentials, credentials}, limit: :infinity) =~ @token
    end

    test "is not logged when the process crashes, and it is not started again", %{
      scope: scope,
      pid: pid
    } do
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          # No clause takes the request, so the process crashes, with its state, its
          # message and the arguments of the function that failed in the report
          message = {:request, OpenTelemetry.Ctx.get_current(), {:unknown, :request}}

          assert {{:function_clause, _stacktrace}, _call} =
                   catch_exit(GenServer.call(pid, message))

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
        end)

      assert log =~ "FunctionClauseError"
      refute log =~ @token

      refute Connection.unlocked?(scope)
      Process.sleep(50)
      refute Connection.unlocked?(scope)
      assert Connection.list_all_invoices(scope) == {:error, :locked}
    end

    test "is not logged when a request crashes the process, which is then locked", %{
      scope: scope
    } do
      Req.Test.stub(IkeEmails.Elorus, fn _conn -> raise "the stub failed" end)

      log =
        capture_log(fn ->
          assert Connection.list_all_invoices(scope) == {:error, :locked}
        end)

      assert log =~ "the stub failed"
      refute log =~ @token
      refute Connection.unlocked?(scope)
    end

    test "is not in what the process logs", %{pid: pid} do
      status = %{
        state: :sys.get_state(pid),
        message: {:put_credentials, elorus_credentials_fixture(api_token: @token), 0},
        reason: :normal,
        log: []
      }

      formatted = Connection.format_status(status)

      refute :erlang.term_to_binary(formatted) =~ @token
      assert formatted.message == :redacted
      assert formatted.state == status.state
    end
  end

  describe "configure_settings/1, for the tests that need Elorus" do
    setup :configure_settings

    test "saves the settings, and unlocks the credentials", %{scope: scope, settings: settings} do
      assert settings.business_name == "Test Business"
      assert settings.elorus_token_set
      assert Settings.business(scope) == %{name: "Test Business", vat: "EL099999999"}
      assert Settings.elorus_configured?(scope)
      assert Connection.unlocked?(scope)

      assert {:ok, credentials} =
               Settings.unseal_elorus_credentials(scope, valid_user_password())

      assert credentials == elorus_credentials_fixture()
    end

    test "makes the stubs of the test reach the process of the connection", %{scope: scope} do
      ElorusStub.stub()

      assert {:ok, []} = Connection.list_all_invoices(scope)

      assert %{
               "authorization" => "Token test-elorus-token",
               "x-elorus-organization" => "1000000243015421"
             } = ElorusStub.last_headers()
    end

    test "is not for a test that is async", %{scope: scope} do
      assert_raise ArgumentError, ~r/cannot be async/, fn ->
        configure_settings(%{scope: scope, async: true})
      end
    end
  end
end
