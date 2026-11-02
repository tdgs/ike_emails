defmodule IkeEmailsWeb.UserAuth do
  @moduledoc """
  Who is logged in. The session holds the id of the user, and every page that is
  not the login needs one: the user is in `current_scope` of the conn and of the
  socket.
  """

  use IkeEmailsWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias IkeEmails.Accounts
  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Elorus.Connection

  @doc """
  Logs the user in: a new session, so that one from before the login (or
  someone else's) is not reused, and on to the page that was asked for.
  """
  def log_in_user(conn, user) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, live_socket_id(user))
    |> redirect(to: user_return_to || ~p"/")
  end

  @doc """
  Logs the user out, and closes the LiveViews they have open. Their Elorus API key,
  if they unlocked it, is locked again.
  """
  def log_out_user(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      IkeEmailsWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    if scope = conn.assigns[:current_scope] do
      Connection.lock(scope)
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  defp live_socket_id(user), do: "users_sessions:#{user.id}"

  # The session is dropped and a new one started, a fixed id could be known to
  # someone else
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Puts the scope of the logged in user in `conn.assigns.current_scope`, or `nil`.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    scope = scope_from_session(get_session(conn))
    put_sentry_user(scope)
    assign(conn, :current_scope, scope)
  end

  @doc """
  Tells Sentry who the errors that follow happen to. It is the id of the user and
  nothing else, no email.

  The context lives as long as the process, and a connection that stays open serves
  the requests that follow with the same one, so for no user the id is cleared.
  """
  def put_sentry_user(%Scope{} = scope),
    do: Sentry.Context.set_user_context(%{id: Scope.user_id(scope)})

  def put_sentry_user(nil), do: Sentry.Context.set_user_context(%{id: nil})

  defp scope_from_session(%{"user_id" => user_id}) do
    user_id |> Accounts.get_user() |> Scope.for_user()
  end

  defp scope_from_session(_session), do: nil

  @doc """
  Used on the pages that need a user: anyone else is sent to the login, and back
  here afterwards.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  Used on the login: whoever is logged in has no use for it.
  """
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns.current_scope do
      conn |> redirect(to: ~p"/") |> halt()
    else
      conn
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  @doc """
  Handlers of `on_mount` for the LiveViews:

    * `:require_authenticated` - assigns `current_scope`, and sends anyone who
      is not logged in to the login.
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn -> scope_from_session(session) end)

    put_sentry_user(socket.assigns.current_scope)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end
end
