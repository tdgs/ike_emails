defmodule IkeEmailsWeb.SessionControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Elorus.Connection

  setup do
    %{user: user_fixture()}
  end

  defp login_params(email, password), do: %{"user" => %{"email" => email, "password" => password}}

  defp has_selector?(document, selector), do: LazyHTML.query(document, selector) |> Enum.any?()

  describe "GET /login" do
    test "renders the login form", %{conn: conn} do
      conn = get(conn, ~p"/login")

      document = conn |> html_response(200) |> LazyHTML.from_fragment()

      assert has_selector?(document, "#login-form")
      assert has_selector?(document, "#login-email")
      assert has_selector?(document, "#login-password")
      refute has_selector?(document, "#nav-invoices")
      refute has_selector?(document, "#logout")
    end

    test "sends a logged in user on", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> get(~p"/login")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /login" do
    test "logs the user in", %{conn: conn, user: user} do
      conn = post(conn, ~p"/login", login_params(user.email, valid_user_password()))

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id) == user.id
      assert_in_delta get_session(conn, :logged_in_at), System.system_time(:second), 5
      assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"

      document = recycle(conn) |> get(~p"/") |> html_response(200) |> LazyHTML.from_fragment()

      assert has_selector?(document, "#logout")
      assert document |> LazyHTML.query("#current-user") |> LazyHTML.text() =~ user.email
    end

    test "takes the email in any case and with spaces around", %{conn: conn, user: user} do
      email = " " <> String.upcase(user.email) <> " "
      conn = post(conn, ~p"/login", login_params(email, valid_user_password()))

      assert redirected_to(conn) == ~p"/"
    end

    test "goes back to the page that was asked for", %{conn: conn, user: user} do
      conn = get(conn, ~p"/invoices")
      assert redirected_to(conn) == ~p"/login"

      conn = post(recycle(conn), ~p"/login", login_params(user.email, valid_user_password()))

      assert redirected_to(conn) == ~p"/invoices"
    end

    test "starts a new session", %{conn: conn, user: user} do
      conn = conn |> init_test_session(%{"stale" => "value"})
      conn = post(conn, ~p"/login", login_params(user.email, valid_user_password()))

      refute get_session(conn, "stale")
    end

    test "refuses a wrong password", %{conn: conn, user: user} do
      conn = post(conn, ~p"/login", login_params(user.email, "not the password"))

      document = conn |> html_response(200) |> LazyHTML.from_fragment()
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
      refute get_session(conn, :user_id)

      # The email stays in the form
      assert document |> LazyHTML.query("#login-email") |> LazyHTML.attribute("value") ==
               [user.email]
    end

    test "refuses an unknown email the same way", %{conn: conn} do
      conn = post(conn, ~p"/login", login_params("nobody@example.com", valid_user_password()))

      assert html_response(conn, 200)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
      refute get_session(conn, :user_id)
    end

    test "refuses a request without the fields", %{conn: conn} do
      conn = post(conn, ~p"/login", %{})

      assert html_response(conn, 200)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
    end
  end

  describe "DELETE /logout" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)

      conn = get(recycle(conn), ~p"/")
      assert redirected_to(conn) == ~p"/login"
    end

    test "disconnects the LiveViews of the user", %{conn: conn, user: user} do
      live_socket_id = "users_sessions:#{user.id}"
      IkeEmailsWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> log_in_user(user)
      |> put_session(:live_socket_id, live_socket_id)
      |> delete(~p"/logout")

      assert_receive %Phoenix.Socket.Broadcast{topic: ^live_socket_id, event: "disconnect"}
    end

    test "locks the Elorus credentials of the user, and of nobody else", %{
      conn: conn,
      user: user
    } do
      scope = user_scope_fixture(user)
      other = user_scope_fixture()
      :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
      :ok = Connection.put_credentials(other, elorus_credentials_fixture())
      assert Connection.unlocked?(scope)

      conn |> log_in_user(user) |> delete(~p"/logout")

      refute Connection.unlocked?(scope)
      assert Connection.unlocked?(other)

      Connection.lock(other)
    end

    test "is fine for someone who is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "pages that need a user" do
    test "send whoever is not logged in to the login", %{conn: conn} do
      for path <- [~p"/", ~p"/invoices", ~p"/invoices/new", ~p"/invoices/1/pdf"] do
        conn = get(conn, path)
        assert redirected_to(conn) == ~p"/login"
      end
    end

    test "send a user that is gone to the login", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      IkeEmails.Repo.delete!(user)

      conn = get(conn, ~p"/")

      assert redirected_to(conn) == ~p"/login"
    end

    # A copy of the cookie stops working, logout or not
    test "send a session older than 14 days to the login", %{conn: conn, user: user} do
      fifteen_days_ago = System.system_time(:second) - 15 * 24 * 60 * 60

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "user_id" => user.id,
          "logged_in_at" => fifteen_days_ago
        })
        |> get(~p"/")

      assert redirected_to(conn) == ~p"/login"
    end

    test "send a session without the time of its login to the login", %{conn: conn, user: user} do
      conn = conn |> Plug.Test.init_test_session(%{"user_id" => user.id}) |> get(~p"/")

      assert redirected_to(conn) == ~p"/login"
    end
  end
end
