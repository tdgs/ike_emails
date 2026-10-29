defmodule IkeEmailsWeb.SessionController do
  use IkeEmailsWeb, :controller

  alias IkeEmails.Accounts
  alias IkeEmailsWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, form: login_form(""))
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        # The same answer for an unknown email and a wrong password
        conn
        |> put_flash(:error, "Invalid email or password.")
        |> render(:new, form: login_form(String.slice(email, 0, 160)))

      user ->
        UserAuth.log_in_user(conn, user)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid email or password.")
    |> render(:new, form: login_form(""))
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out.")
    |> UserAuth.log_out_user()
  end

  defp login_form(email), do: Phoenix.Component.to_form(%{"email" => email}, as: :user)
end
