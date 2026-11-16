defmodule Mix.Tasks.User.Create do
  @shortdoc "Creates a user"

  @moduledoc """
  Creates a user. There is no sign-up page: this is how people get an account.

      mix user.create EMAIL

  It asks for the password at the terminal, without showing it, so that it is not in
  the history of the shell. The password has at least 12 characters. In production,
  where there is no Mix, use `IkeEmails.Release.create_user/1`.
  """

  use Mix.Task

  alias IkeEmails.Terminal

  @requirements ["app.start"]

  @impl Mix.Task
  def run([email]) do
    password =
      case Terminal.read_secret("Password (not shown, at least 12 characters): ") do
        {:ok, password} -> password
        {:error, reason} -> Mix.raise(Terminal.message(reason))
      end

    case IkeEmails.Accounts.register_user(%{email: email, password: password}) do
      {:ok, user} ->
        Mix.shell().info("Created the user #{user.email}.")

      {:error, changeset} ->
        Mix.raise(
          "Could not create the user: " <>
            inspect(
              Ecto.Changeset.traverse_errors(
                changeset,
                &IkeEmailsWeb.CoreComponents.translate_error/1
              )
            )
        )
    end
  end

  def run(_args), do: Mix.raise("Usage: mix user.create EMAIL")
end
