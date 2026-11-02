defmodule IkeEmailsWeb.AuthLiveTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  describe "without a user" do
    test "the pages are not shown, the login is", %{conn: conn} do
      for path <- [~p"/", ~p"/invoices", ~p"/invoices/new", ~p"/settings"] do
        assert {:error, {:redirect, %{to: "/login"}}} = live(conn, path)
      end
    end

    test "the transaction and invoice pages are not shown either", %{conn: conn} do
      owner = user_scope_fixture()
      transaction = transaction_fixture(owner)
      invoice = invoice_fixture(owner)

      for path <- [~p"/transactions/#{transaction.id}/invoice", ~p"/invoices/#{invoice.id}/edit"] do
        assert {:error, {:redirect, %{to: "/login"}}} = live(conn, path)
      end
    end

    test "the PDF of an invoice is not served", %{conn: conn} do
      invoice = invoice_fixture(user_scope_fixture())

      conn = get(conn, ~p"/invoices/#{invoice.id}/pdf")

      assert redirected_to(conn) == ~p"/login"
    end

    test "a session of a user that is gone is no session", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:ok, _user} = IkeEmails.Repo.delete(user)

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end

    test "the login has no navigation", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#login-form") |> Enum.count() == 1
      assert LazyHTML.query(document, "#nav-reconciliation") |> Enum.count() == 0
      assert LazyHTML.query(document, "#nav-invoices") |> Enum.count() == 0
      assert LazyHTML.query(document, "#nav-settings") |> Enum.count() == 0
      assert LazyHTML.query(document, "#logout") |> Enum.count() == 0
    end
  end

  describe "with a user" do
    setup :register_and_log_in_user

    test "the layout shows who is logged in, and the way out", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#current-user", user.email)
      assert has_element?(view, "#logout[href='/logout']")
      assert has_element?(view, "#nav-reconciliation")
      assert has_element?(view, "#nav-invoices")
      assert has_element?(view, "#nav-settings")
    end

    test "the reconciliation shows their transactions only", %{conn: conn, scope: scope} do
      mine = transaction_fixture(scope)
      theirs = transaction_fixture(user_scope_fixture())

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      assert has_element?(view, "#transactions-#{mine.id}")
      refute has_element?(view, "#transactions-#{theirs.id}")
    end

    test "the months are theirs too", %{conn: conn} do
      transaction_fixture(user_scope_fixture(), %{"date" => "2026-03-02"})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#month-select option[value='2026-03']")
    end

    test "the invoices are theirs only", %{conn: conn, scope: scope} do
      mine = invoice_fixture(scope)
      theirs = invoice_fixture(user_scope_fixture())

      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#invoices-#{mine.id}")
      refute has_element?(view, "#invoices-#{theirs.id}")
    end

    test "the suggestions are theirs only", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      mine = invoice_fixture(scope)
      theirs = invoice_fixture(user_scope_fixture())

      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      assert has_element?(view, "#suggestions-#{mine.id}")
      refute has_element?(view, "#suggestions-#{theirs.id}")
    end

    test "the invoice of another user cannot be edited", %{conn: conn} do
      invoice = invoice_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/invoices/#{invoice.id}/edit") end
    end

    test "the transaction of another user cannot be opened", %{conn: conn} do
      transaction = transaction_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")
      end
    end

    test "the PDF of another user's invoice is not found", %{conn: conn} do
      invoice = invoice_fixture(user_scope_fixture())

      assert_error_sent 404, fn -> get(conn, ~p"/invoices/#{invoice.id}/pdf") end
    end

    test "the PDF of their own invoice is served", %{conn: conn, scope: scope} do
      invoice = invoice_fixture(scope)

      conn = get(conn, ~p"/invoices/#{invoice.id}/pdf")

      assert redirected_to(conn, 302) =~ invoice.file_key
    end

    @tag :capture_log
    test "another user's invoice is not deleted by its id", %{conn: conn, scope: scope} do
      mine = invoice_fixture(scope)
      theirs = invoice_fixture(user_scope_fixture())
      {:ok, view, _html} = live(conn, ~p"/invoices")
      Process.flag(:trap_exit, true)

      # The row is not on the page, but the event can be sent with any id
      catch_exit(render_hook(view, "delete", %{"id" => to_string(theirs.id)}))

      assert_receive {:EXIT, _pid, {%Ecto.NoResultsError{}, _stacktrace}}
      assert IkeEmails.Invoicing.get_invoice!(scope, mine.id)
      assert IkeEmails.Repo.get(IkeEmails.Invoicing.Invoice, theirs.id)
    end
  end
end
