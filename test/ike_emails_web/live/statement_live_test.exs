defmodule IkeEmailsWeb.StatementLiveTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "the list" do
    test "shows the statements with a link to their PDF", %{conn: conn, scope: scope} do
      statement = statement_fixture(scope, "2026-10")

      {:ok, view, _html} = live(conn, ~p"/statements")

      assert has_element?(view, "#statements-#{statement.id}", "October 2026")
      assert has_element?(view, "#statements-#{statement.id}", "statement.pdf")
      assert has_element?(view, "#pdf-#{statement.id}[href='/statements/#{statement.id}/pdf']")
    end

    test "has the latest month first", %{conn: conn, scope: scope} do
      september = statement_fixture(scope, "2026-09")
      october = statement_fixture(scope, "2026-10")
      august = statement_fixture(scope, "2026-08")

      {:ok, view, _html} = live(conn, ~p"/statements")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#statements > div")
        |> LazyHTML.attribute("id")
        |> Enum.reject(&(&1 == "statements-empty"))

      assert ids == Enum.map([october, september, august], &"statements-#{&1.id}")
    end

    test "says so when there are none", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/statements")

      assert has_element?(view, "#statements-empty", "No statements yet.")
    end

    test "leaves out the statements of other users", %{conn: conn, scope: scope} do
      mine = statement_fixture(scope, "2026-10")
      theirs = statement_fixture(user_scope_fixture(), "2026-09")

      {:ok, view, _html} = live(conn, ~p"/statements")

      assert has_element?(view, "#statements-#{mine.id}")
      refute has_element?(view, "#statements-#{theirs.id}")
    end

    test "is in the navigation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#nav-statements") |> render_click()

      assert_redirect(view, ~p"/statements")
    end

    test "sends whoever is not logged in to the login" do
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/statements")
    end
  end
end
