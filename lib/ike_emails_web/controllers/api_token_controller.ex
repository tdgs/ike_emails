defmodule IkeEmailsWeb.ApiTokenController do
  use IkeEmailsWeb, :controller

  alias IkeEmails.Accounts
  alias IkeEmailsWeb.ApiToken
  alias IkeEmailsWeb.Plugs.ApiAuth

  @doc """
  Trades the email and password of a user for a token to push their transactions
  with. Whatever is wrong with the request, the answer is the same.
  """
  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil -> ApiAuth.unauthorized(conn)
      user -> render(conn, :show, token: ApiToken.generate(user), expires_in: ApiToken.max_age())
    end
  end

  def create(conn, _params), do: ApiAuth.unauthorized(conn)
end
