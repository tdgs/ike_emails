defmodule Mix.Tasks.User.Create do
  @shortdoc "Creates a user"

  @moduledoc """
  Creates a user. There is no sign-up page: this is how people get an account.

      mix user.create EMAIL PASSWORD

  The password has at least 12 characters. In production, where there is no Mix,
  use `IkeEmails.Release.create_user/2`.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([email, password]) do
    case IkeEmails.Accounts.register_user(%{email: email, password: password}) do
      {:ok, user} ->
        Mix.shell().info("Created the user #{user.email}.")

      {:error, changeset} ->
        Mix.raise(
          "Could not create the user: " <>
            inspect(IkeEmails.Accounts.error_messages(changeset))
        )
    end
  end

  def run(_args), do: Mix.raise("Usage: mix user.create EMAIL PASSWORD")
end
