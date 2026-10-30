defmodule IkeEmailsWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates the external services that push data to the API with the bearer
  token of a user, see `IkeEmailsWeb.ApiToken`. The scope of that user is put in
  `conn.assigns.current_scope`, so that what is pushed is theirs.
  """

  import Plug.Conn

  alias IkeEmails.Accounts
  alias IkeEmails.Accounts.Scope
  alias IkeEmailsWeb.ApiToken
  alias IkeEmailsWeb.UserAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user_id} <- ApiToken.verify(token),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      scope = Scope.for_user(user)
      UserAuth.put_sentry_user(scope)
      assign(conn, :current_scope, scope)
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  Answers a request that is not allowed.
  """
  def unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{errors: %{detail: "Unauthorized"}})
    |> halt()
  end
end
