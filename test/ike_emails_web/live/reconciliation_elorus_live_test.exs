defmodule IkeEmailsWeb.ReconciliationElorusLiveTest do
  # Not async: the Elorus stub is shared with the process of the credentials of the
  # user, which makes the requests, and some tests change the settings
  use IkeEmailsWeb.ConnCase, async: false

  import IkeEmails.ElorusStub
  import Ecto.Query, only: [from: 2]
  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  alias IkeEmails.Banking
  alias IkeEmails.Elorus
  alias IkeEmails.Elorus.Connection
  alias IkeEmails.Invoicing
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Repo
  alias IkeEmails.Settings
  alias IkeEmails.Settings.UserSettings

  # The tasks that call Elorus, and the failures they cause, are logged
  @moduletag :capture_log

  setup :register_and_log_in_user
  # The settings of the user are saved, and their credentials unlocked
  setup :configure_settings

  defp income(scope, attrs \\ %{}),
    do: transaction_fixture(scope, Map.merge(%{"amount" => "100.00"}, attrs))

  defp panel(transaction, month \\ "2026-10"),
    do: ~p"/transactions/#{transaction.id}/invoice?month=#{month}"

  defp elorus_row(id), do: "#elorus_invoices-#{id}"

  # The results arrive from a task, after the click
  defp wait_for(view, selector, tries \\ 500) do
    cond do
      has_element?(view, selector) -> :ok
      tries == 0 -> flunk("#{selector} did not show up")
      true -> Process.sleep(10) && wait_for(view, selector, tries - 1)
    end
  end

  # The stubs that hold a request run in the process of the credentials, which goes on
  # when they are released: what ends is the task of the page that waits for them
  defp release(connection) do
    send(connection, :release)
    wait_for_tasks()
  end

  defp wait_for_tasks(tries \\ 500) do
    cond do
      Task.Supervisor.children(IkeEmails.TaskSupervisor) == [] -> :ok
      tries == 0 -> flunk("the task did not end")
      true -> Process.sleep(10) && wait_for_tasks(tries - 1)
    end
  end

  defp wait_until_locked(scope, tries \\ 500) do
    cond do
      not Connection.unlocked?(scope) -> :ok
      tries == 0 -> flunk("the credentials were not locked")
      true -> Process.sleep(10) && wait_until_locked(scope, tries - 1)
    end
  end

  # The process of the connection is made busy with a request that does not end until
  # it is released, so an unlock waits for it, after it opened the key. Returns it.
  defp hold_connection(scope) do
    test = self()

    Req.Test.stub(Elorus, fn conn ->
      send(test, {:blocked, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :timeout
      end

      Req.Test.json(conn, %{"count" => 0, "next" => nil, "previous" => nil, "results" => []})
    end)

    :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
    Task.async(fn -> Connection.list_all_invoices(scope) end)
    assert_receive {:blocked, connection}, 5_000
    connection
  end

  # What it takes for the key to be opened and the unlock to wait for the process
  defp wait_until_queued(connection, tries \\ 500) do
    cond do
      Process.info(connection, :message_queue_len) == {:message_queue_len, 1} -> :ok
      tries == 0 -> flunk("the unlock did not wait for the process")
      true -> Process.sleep(10) && wait_until_queued(connection, tries - 1)
    end
  end

  defp search(view) do
    view |> element("#search-elorus") |> render_click()
  end

  defp unlock(view, password) do
    view |> form("#elorus-unlock-form", %{"password" => password}) |> render_submit()
  end

  defp listed_ids(view) do
    view
    |> element("#elorus-invoices")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^=elorus_invoices-]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "elorus_invoices-", ""))
  end

  describe "the section" do
    test "is there for money in, with a button, and asks nothing yet", %{conn: conn, scope: scope} do
      stub()
      {:ok, view, _html} = live(conn, panel(income(scope)))

      assert has_element?(view, "#elorus-section")
      assert has_element?(view, "#search-elorus", "October 2026")
      refute has_element?(view, "#elorus-invoices")
      refute_receive {:elorus_request, _}, 200
    end

    test "is not there for money out", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, panel(transaction_fixture(scope, %{"amount" => "-100.00"})))

      assert has_element?(view, "#attach-panel")
      refute has_element?(view, "#elorus-section")
    end

    test "tells how to set Elorus up when it is not", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json()])
      Settings.clear_elorus_token(scope)

      {:ok, view, _html} = live(conn, panel(income(scope)))

      assert has_element?(view, "#elorus-unconfigured a[href='/settings']")
      refute has_element?(view, "#search-elorus")
      refute has_element?(view, "#elorus-unlock-form")

      render_hook(view, "search_elorus", %{})

      refute_receive {:elorus_request, _}, 200
      refute has_element?(view, "#elorus-error")
      refute has_element?(view, "#elorus-invoices")
    end

    test "tells how to set Elorus up when it has no organization", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json()])
      {:ok, _} = Settings.update_settings(scope, %{"elorus_organization_id" => ""})

      {:ok, view, _html} = live(conn, panel(income(scope)))

      assert has_element?(view, "#elorus-unconfigured a[href='/settings']")
      refute has_element?(view, "#search-elorus")
      refute has_element?(view, "#elorus-unlock-form")
    end

    test "is not set up for a user who has not saved settings", %{conn: conn} do
      stub(invoices: [invoice_json()])
      user = user_fixture()
      scope = user_scope_fixture(user)

      {:ok, view, _html} = live(log_in_user(conn, user), panel(income(scope)))

      assert has_element?(view, "#elorus-unconfigured")
      refute has_element?(view, "#search-elorus")
    end

    test "does not use the credentials that another user unlocked", %{conn: conn} do
      stub(invoices: [invoice_json()])
      user = user_fixture()
      scope = user_scope_fixture(user)
      settings_fixture(scope, %{"elorus_organization_id" => "2000000000000002"})

      # Their own are not unlocked, though those of the user of the test are
      {:ok, view, _html} = live(log_in_user(conn, user), panel(income(scope)))

      assert has_element?(view, "#elorus-unlock-form")
      refute has_element?(view, "#search-elorus")
    end
  end

  describe "locked" do
    setup %{scope: scope} do
      Connection.lock(scope)
      :ok
    end

    test "asks for the password before it offers a search", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json()])

      {:ok, view, _html} = live(conn, panel(income(scope)))

      assert has_element?(view, "#elorus-unlock-form")
      assert has_element?(view, "#elorus-unlock-form input[type=password][name=password]")
      assert has_element?(view, "#elorus-unlock-form input[autocomplete=current-password]")
      refute has_element?(view, "#search-elorus")
      refute has_element?(view, "#elorus-unconfigured")
      refute has_element?(view, "#elorus-error")

      render_hook(view, "search_elorus", %{})

      refute_receive {:elorus_request, _}, 200
      refute has_element?(view, "#elorus-invoices")
    end

    test "asks again when the panel is opened after the window ended", %{
      conn: conn,
      scope: scope
    } do
      stub()
      transaction = income(scope)
      :ok = Connection.put_credentials(scope, elorus_credentials_fixture())

      {:ok, view, _html} = live(conn, panel(transaction))
      assert has_element?(view, "#search-elorus")

      Connection.lock(scope)
      render_patch(view, ~p"/?month=2026-10")
      render_patch(view, panel(transaction))

      assert has_element?(view, "#elorus-unlock-form")
      refute has_element?(view, "#search-elorus")
    end

    test "unlocks with the password, and searches", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      {:ok, view, _html} = live(conn, panel(income(scope)))

      unlock(view, valid_user_password())
      wait_for(view, "#search-elorus")

      refute has_element?(view, "#elorus-unlock-form")
      refute has_element?(view, "#elorus-error")
      assert Connection.unlocked?(scope)
      refute_receive {:elorus_request, _}, 100

      search(view)
      wait_for(view, elorus_row("a"))

      assert %{
               "authorization" => "Token test-elorus-token",
               "x-elorus-organization" => "1000000243015421"
             } = last_headers()

      # Nothing of the password or the API key is in the page
      html = render(view)
      refute html =~ valid_user_password()
      refute html =~ "test-elorus-token"
    end

    test "refuses a wrong password, and keeps asking", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json()])
      {:ok, view, _html} = live(conn, panel(income(scope)))

      unlock(view, "not the password 123")
      wait_for(view, "#elorus-error")

      assert has_element?(view, "#elorus-error", "That password is not right")
      assert has_element?(view, "#elorus-unlock-form")
      refute has_element?(view, "#search-elorus")
      refute Connection.unlocked?(scope)
      refute render(view) =~ "not the password 123"

      render_hook(view, "search_elorus", %{})
      refute_receive {:elorus_request, _}, 100

      # The right one works afterwards, and the message is gone
      unlock(view, valid_user_password())
      wait_for(view, "#search-elorus")
      refute has_element?(view, "#elorus-error")
    end

    test "says when the saved API key cannot be opened", %{conn: conn, scope: scope} do
      user_id = scope.user.id

      {1, _} =
        Repo.update_all(
          from(s in UserSettings, where: s.user_id == ^user_id),
          set: [elorus_token_salt: Base.url_encode64("another salt 1234", padding: false)]
        )

      {:ok, view, _html} = live(conn, panel(income(scope)))

      unlock(view, valid_user_password())
      wait_for(view, "#elorus-error")

      assert has_element?(view, "#elorus-error", "cannot be unlocked")
      assert has_element?(view, "#elorus-unlock-form")
      refute Connection.unlocked?(scope)
    end

    test "follows the settings when the API key was removed meanwhile", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, panel(income(scope)))
      Settings.clear_elorus_token(scope)

      unlock(view, valid_user_password())
      wait_for(view, "#elorus-unconfigured")

      assert has_element?(view, "#elorus-unconfigured a[href='/settings']")
      assert has_element?(view, "#elorus-error", "in Settings")
      refute has_element?(view, "#elorus-unlock-form")
    end

    test "unlocks once when the form is sent twice", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, panel(income(scope)))
      connection = hold_connection(scope)

      # The first is in the middle of it, and stays until the process is released
      unlock(view, valid_user_password())
      wait_until_queued(connection)
      assert has_element?(view, "#unlock-elorus[disabled]")
      {:links, links} = Process.info(view.pid, :links)

      render_hook(view, "unlock_elorus", %{"password" => valid_user_password()})

      # No other task opens the key
      assert Process.info(view.pid, :links) == {:links, links}
      assert Process.info(connection, :message_queue_len) == {:message_queue_len, 1}

      release(connection)
      wait_for(view, "#search-elorus")

      refute has_element?(view, "#elorus-error")
      assert Connection.unlocked?(scope)
    end

    test "asks again when it was locked while the key was opened", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, panel(income(scope)))
      connection = hold_connection(scope)

      unlock(view, valid_user_password())
      wait_until_queued(connection)

      # The user removed the key, or changed the organization, in another tab
      Connection.lock(scope)
      wait_for(view, "#elorus-error")

      assert has_element?(view, "#elorus-error", "Enter your password to use Elorus again")
      assert has_element?(view, "#elorus-unlock-form")
      refute has_element?(view, "#search-elorus")
      refute Connection.unlocked?(scope)
    end

    test "ignores an unlock that is not for a locked panel", %{conn: conn, scope: scope} do
      stub()
      :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
      {:ok, view, _html} = live(conn, panel(income(scope)))

      render_hook(view, "unlock_elorus", %{"password" => "not the password 123"})

      refute has_element?(view, "#elorus-error")
      assert has_element?(view, "#search-elorus")
      assert Connection.unlocked?(scope)
    end

    test "keeps the password out of the logs and the state of the view", %{
      conn: conn,
      scope: scope
    } do
      stub()
      {:ok, view, _html} = live(conn, panel(income(scope)))
      password = valid_user_password()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          unlock(view, password)
          wait_for(view, "#search-elorus")
        end)

      refute log =~ password

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.elorus_state == :unlocked
      refute inspect(assigns, limit: :infinity) =~ password
      refute inspect(assigns, limit: :infinity) =~ "test-elorus-token"
    end
  end

  describe "when the window ends" do
    test "a search asks for the password again", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json()])
      {:ok, view, _html} = live(conn, panel(income(scope)))
      assert has_element?(view, "#search-elorus")

      # What the idle timeout of the process does
      Connection.lock(scope)
      search(view)

      wait_for(view, "#elorus-unlock-form")
      assert has_element?(view, "#elorus-error", "Enter your password to use Elorus again")
      refute has_element?(view, "#search-elorus")
      refute_receive {:elorus_request, _}, 100

      unlock(view, valid_user_password())
      wait_for(view, "#search-elorus")
      refute has_element?(view, "#elorus-error")
    end

    test "ends by itself when it is not used", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json()])
      {:ok, view, _html} = live(conn, panel(income(scope)))
      assert has_element?(view, "#search-elorus")

      # What the end of the window sends to the process: the timer is tested with it
      assert [{connection, _}] = Registry.lookup(IkeEmails.Elorus.Registry, scope.user.id)
      send(connection, :timeout)
      wait_until_locked(scope)
      search(view)

      wait_for(view, "#elorus-unlock-form")
      assert has_element?(view, "#elorus-error", "Enter your password to use Elorus again")
      refute has_element?(view, "#search-elorus")
    end

    test "an import asks for the password again, and does not store anything", %{
      conn: conn,
      scope: scope
    } do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")

      Connection.lock(scope)
      view |> element("#attach-elorus-a") |> render_click()

      wait_for(view, "#elorus-unlock-form")
      assert has_element?(view, "#elorus-error", "Enter your password to use Elorus again")
      assert has_element?(view, "#attach-panel")
      assert Banking.get_transaction!(scope, transaction.id).invoices == []
      assert Repo.aggregate(Invoice, :count) == 0

      # The invoices that were listed stay
      assert has_element?(view, elorus_row("a"))
      assert request_paths() == ["/v1.2/invoices/"]
    end

    test "an invoice that was imported before is attached without the password", %{
      conn: conn,
      scope: scope
    } do
      stub(invoices: [invoice_json(%{"id" => "a"})])

      {:ok, _} =
        Invoicing.import_elorus_invoice(
          scope,
          Elorus.Invoice.from_api(invoice_json(%{"id" => "a"})),
          income(scope)
        )

      transaction = income(scope)
      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      request_paths()

      Connection.lock(scope)
      view |> element("#attach-elorus-a") |> render_click()
      assert_patch(view, ~p"/?month=2026-10", 5_000)

      assert request_paths() == []
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
    end

    test "ends in the middle of an import, which says so when the panel was closed", %{
      conn: conn,
      scope: scope
    } do
      stub_slow_pdf()
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_receive {:blocked, _connection}, 5_000

      render_patch(view, ~p"/?month=2026-10")
      Connection.lock(scope)
      wait_for(view, "#flash-error")

      assert has_element?(view, "#flash-error", "was not attached")
      assert has_element?(view, "#flash-error", "Enter your password to use Elorus again")
      assert Repo.aggregate(Invoice, :count) == 0

      render_patch(view, panel(transaction))
      assert has_element?(view, "#elorus-unlock-form")
      refute has_element?(view, "#search-elorus")
    end
  end

  describe "searching" do
    test "lists the invoices of the month, the ones for the amount first", %{
      conn: conn,
      scope: scope
    } do
      stub(
        invoices: [
          invoice_json(%{"id" => "a", "total" => "30.00", "payable" => "30.00"}),
          invoice_json(%{"id" => "b", "total" => "100.00", "payable" => "100.00"}),
          invoice_json(%{"id" => "c", "total" => "50.00", "payable" => "50.00"}),
          invoice_json(%{"id" => "d", "total" => "125.00", "payable" => "100.00"})
        ]
      )

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)
      wait_for(view, "#elorus-invoices")

      assert listed_ids(view) == ["b", "d", "a", "c"]
      assert has_element?(view, elorus_row("b"), "same amount")
      assert has_element?(view, elorus_row("d"), "same amount")
      refute has_element?(view, elorus_row("a"), "same amount")
      assert has_element?(view, elorus_row("a"), "Acme Inc.")
      assert has_element?(view, elorus_row("a"), "30,00 €")
      assert has_element?(view, "#{elorus_row("a")} a[href='https://app.elorus.com/p/abc/']")
      assert has_element?(view, "#attach-elorus-a")
    end

    test "asks for the month that is shown, not the one of the transaction", %{
      conn: conn,
      scope: scope
    } do
      stub()
      transaction = income(scope, %{"date" => "2026-09-14"})

      {:ok, view, _html} = live(conn, panel(transaction, "2026-08"))
      assert has_element?(view, "#search-elorus", "August 2026")
      search(view)
      wait_for(view, "#elorus-empty")

      assert %{"period_from" => "2026-08-01", "period_to" => "2026-08-31"} = last_query()
    end

    test "says so when the month has no invoices", %{conn: conn, scope: scope} do
      stub(invoices: [])

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)

      wait_for(view, "#elorus-empty")
      assert has_element?(view, "#elorus-empty", "October 2026")
    end

    test "marks the invoices that were imported", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"}), invoice_json(%{"id" => "b"})])

      {:ok, _} =
        Invoicing.import_elorus_invoice(
          scope,
          Elorus.Invoice.from_api(invoice_json(%{"id" => "b"})),
          income(scope)
        )

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)
      wait_for(view, elorus_row("a"))

      refute has_element?(view, elorus_row("a"), "stored")
      assert has_element?(view, elorus_row("b"), "stored")
    end

    for {status, message} <- [
          {401, "refused the API key"},
          {403, "refused the API key"},
          {429, "limiting requests"},
          {500, "unexpected status (500)"}
        ] do
      test "shows the failure when Elorus answers #{status}", %{conn: conn, scope: scope} do
        stub(status: unquote(status))

        {:ok, view, _html} = live(conn, panel(income(scope)))
        search(view)

        wait_for(view, "#elorus-error")
        assert has_element?(view, "#elorus-error", unquote(message))
        refute has_element?(view, "#elorus-invoices")
        assert has_element?(view, "#search-elorus:not([disabled])")
      end
    end

    test "can be tried again after a failure", %{conn: conn, scope: scope} do
      stub(status: 500)
      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)
      wait_for(view, "#elorus-error")

      stub(invoices: [invoice_json(%{"id" => "a"})])
      search(view)
      wait_for(view, elorus_row("a"))

      refute has_element?(view, "#elorus-error")
    end

    test "shows a task that died as a failure", %{conn: conn, scope: scope} do
      test = self()

      Req.Test.stub(Elorus, fn conn ->
        send(test, {:blocked, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :timeout
        end

        Req.Test.json(conn, %{"count" => 0, "next" => nil, "previous" => nil, "results" => []})
      end)

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)
      assert_receive {:blocked, connection}, 5_000

      assert [task] = Task.Supervisor.children(IkeEmails.TaskSupervisor)
      Process.exit(task, :kill)

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "Something went wrong with Elorus")
      assert has_element?(view, "#search-elorus:not([disabled])")

      send(connection, :release)
    end

    test "locks Elorus when a request crashes the process of the credentials", %{
      conn: conn,
      scope: scope
    } do
      Req.Test.stub(Elorus, fn _conn -> raise "boom" end)

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)

      wait_for(view, "#elorus-unlock-form")
      assert has_element?(view, "#elorus-error", "Enter your password to use Elorus again")
      refute has_element?(view, "#search-elorus")
      refute Connection.unlocked?(scope)
    end

    test "shows a failed connection as such", %{conn: conn, scope: scope} do
      Req.Test.stub(Elorus, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "Could not reach Elorus")
    end

    test "tells how long to wait when Elorus limits the requests", %{conn: conn, scope: scope} do
      Req.Test.stub(Elorus, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "42")
        |> Plug.Conn.send_resp(429, "")
      end)

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "Try again in 42 seconds")
    end

    test "runs one task at a time, and forgets the one of a closed panel", %{
      conn: conn,
      scope: scope
    } do
      test = self()

      Req.Test.stub(Elorus, fn conn ->
        send(test, {:blocked, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :timeout
        end

        Req.Test.json(conn, %{
          "count" => 1,
          "next" => nil,
          "previous" => nil,
          "results" => [invoice_json(%{"id" => "late"})]
        })
      end)

      transaction = income(scope)
      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      assert_receive {:blocked, task}, 5_000

      assert has_element?(view, "#search-elorus[disabled]", "Searching")
      render_hook(view, "search_elorus", %{})
      refute_receive {:blocked, _other}, 100

      # The panel is closed, and opened again, before the answer comes
      render_patch(view, ~p"/?month=2026-10")
      render_patch(view, panel(transaction))

      release(task)
      # What the page does with the answer is done once it answers this
      render(view)

      assert has_element?(view, "#search-elorus:not([disabled])")
      refute has_element?(view, "#elorus-invoices")
      refute has_element?(view, elorus_row("late"))
    end
  end

  describe "attaching" do
    test "stores the invoice with its PDF, attaches it and closes the panel", %{
      conn: conn,
      scope: scope
    } do
      stub(invoices: [invoice_json(%{"id" => "a", "total" => "100.00"})])
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")

      view |> element("#attach-elorus-a") |> render_click()
      assert_patch(view, ~p"/?month=2026-10", 5_000)

      assert has_element?(view, "#flash-info", "Invoice attached from Elorus")
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      refute has_element?(view, "#attach-panel")

      assert [%Invoice{elorus_id: "a", amount_cents: 10_000, receiver_name: "Acme Inc."}] =
               Banking.get_transaction!(scope, transaction.id).invoices
    end

    test "does not download again an invoice that was imported", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"})])

      {:ok, _} =
        Invoicing.import_elorus_invoice(
          scope,
          Elorus.Invoice.from_api(invoice_json(%{"id" => "a"})),
          income(scope)
        )

      request_paths()

      transaction = income(scope)
      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_patch(view, ~p"/?month=2026-10", 5_000)

      assert request_paths() == ["/v1.2/invoices/"]
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      assert Repo.aggregate(Invoice, :count) == 1
    end

    test "shows why when the PDF cannot be downloaded", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"})], pdf_status: 404)
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "does not have that invoice")
      assert has_element?(view, "#attach-panel")
      assert has_element?(view, elorus_row("a"))
      assert Banking.get_transaction!(scope, transaction.id).invoices == []
    end

    test "says when the business has no name", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      {:ok, _} = Settings.update_settings(scope, %{"business_name" => ""})

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "name of your business in Settings")
      refute has_element?(view, "#elorus-unlock-form")
      assert request_paths() == ["/v1.2/invoices/"]
    end

    test "says what is wrong with an invoice that cannot be stored", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a", "total" => "99999999999.00"})])

      {:ok, view, _html} = live(conn, panel(income(scope)))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()

      wait_for(view, "#elorus-error")
      assert has_element?(view, "#elorus-error", "amount input is too large")
    end

    test "ignores an id that was not listed", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      request_paths()

      render_hook(view, "attach_elorus", %{"id" => "not-listed"})
      render_hook(view, "attach_elorus", %{"id" => "../../x"})

      refute_receive {:elorus_request, _}, 200
      refute has_element?(view, "#elorus-error")
      assert Banking.get_transaction!(scope, transaction.id).invoices == []
    end

    test "is not possible for money out", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      transaction = transaction_fixture(scope, %{"amount" => "-100.00"})

      {:ok, view, _html} = live(conn, panel(transaction))
      render_hook(view, "search_elorus", %{})

      refute_receive {:elorus_request, _}, 200
      refute has_element?(view, "#elorus-error")
    end
  end

  describe "an import that takes a while" do
    # Lists one invoice at once, and holds the download of its PDF until released
    defp stub_slow_pdf(pdf_status \\ 200) do
      test = self()

      Req.Test.stub(Elorus, fn conn ->
        case String.split(conn.request_path, "/", trim: true) do
          ["v1.2", "invoices"] ->
            send(test, {:elorus_request, conn})

            Req.Test.json(conn, %{
              "count" => 1,
              "next" => nil,
              "previous" => nil,
              "results" => [invoice_json(%{"id" => "a"})]
            })

          ["v1.2", "invoices", "a", "pdf"] ->
            send(test, {:elorus_request, conn})
            send(test, {:blocked, self()})

            receive do
              :release -> :ok
            after
              5_000 -> :timeout
            end

            if pdf_status == 200 do
              conn
              |> Plug.Conn.put_resp_content_type("application/pdf")
              |> Plug.Conn.send_resp(200, pdf("a"))
            else
              Plug.Conn.send_resp(conn, pdf_status, "")
            end
        end
      end)
    end

    test "shows that it runs, and keeps the buttons from being used", %{conn: conn, scope: scope} do
      stub_slow_pdf()
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      refute has_element?(view, "#elorus-invoices[data-busy]")

      view |> element("#attach-elorus-a") |> render_click()
      assert_receive {:blocked, task}, 5_000

      assert has_element?(view, "#elorus-invoices[data-busy]")
      assert has_element?(view, "#elorus-importing")
      assert has_element?(view, "#search-elorus[disabled]")

      # A second click is ignored
      render_hook(view, "attach_elorus", %{"id" => "a"})
      refute_receive {:blocked, _other}, 100

      release(task)
      assert_patch(view, ~p"/?month=2026-10", 5_000)
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
    end

    test "goes on when the panel is closed, and brings the rows up to date", %{
      conn: conn,
      scope: scope
    } do
      stub_slow_pdf()
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_receive {:blocked, task}, 5_000

      render_patch(view, ~p"/?month=2026-10")
      assert has_element?(view, "#status-#{transaction.id}[data-status=income]")

      # Neither a search nor a second import can start meanwhile, even if the
      # panel of the transaction is opened again
      render_patch(view, panel(transaction))
      render_hook(view, "search_elorus", %{})
      assert has_element?(view, "#search-elorus[disabled]")

      release(task)
      wait_for(view, "#flash-info")

      assert has_element?(view, "#flash-info", "Invoice attached from Elorus")
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      assert Repo.aggregate(Invoice, :count) == 1
      assert request_paths() == ["/v1.2/invoices/", "/v1.2/invoices/a/pdf/"]
    end

    test "reports a failure with a message when the panel was closed", %{conn: conn, scope: scope} do
      stub_slow_pdf(404)
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_receive {:blocked, task}, 5_000

      render_patch(view, ~p"/?month=2026-10")
      release(task)
      wait_for(view, "#flash-error")

      assert has_element?(view, "#flash-error", "was not attached")
      assert has_element?(view, "#flash-error", "does not have that invoice")
      assert has_element?(view, "#status-#{transaction.id}[data-status=income]")
    end
  end

  describe "the receiver" do
    test "shows in the invoice that was attached", %{conn: conn, scope: scope} do
      stub(invoices: [invoice_json(%{"id" => "a"})])
      transaction = income(scope)

      {:ok, view, _html} = live(conn, panel(transaction))
      search(view)
      wait_for(view, "#attach-elorus-a")
      view |> element("#attach-elorus-a") |> render_click()
      assert_patch(view, ~p"/?month=2026-10", 5_000)

      assert [%Invoice{id: id}] = Banking.get_transaction!(scope, transaction.id).invoices

      assert has_element?(
               view,
               "#transactions-#{transaction.id}-invoice-#{id}",
               "Test Business"
             )

      assert has_element?(view, "#transactions-#{transaction.id}-invoice-#{id}", "Acme Inc.")
    end
  end
end
