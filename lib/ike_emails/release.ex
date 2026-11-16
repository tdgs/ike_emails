defmodule IkeEmails.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :ike_emails

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Creates a user. There is no sign-up page, so this is how users are made in
  production, where there is no Mix. It asks for the password at the terminal, without
  showing it, so that it is not in the history of the shell or the output of Kamal:

      kamal app exec -i 'bin/ike_emails eval "IkeEmails.Release.create_user(~s(me@example.com))"'
  """
  def create_user(email) do
    password =
      case IkeEmails.Terminal.read_secret("Password (not shown, at least 12 characters): ") do
        {:ok, password} ->
          password

        {:error, reason} ->
          IO.puts(IkeEmails.Terminal.message(reason))
          System.halt(1)
      end

    load_app()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(IkeEmails.Repo, fn _repo ->
        IkeEmails.Accounts.register_user(%{email: email, password: password})
      end)

    case result do
      {:ok, user} ->
        IO.puts("Created the user #{user.email}.")

      {:error, changeset} ->
        IO.puts(
          "Could not create the user: #{inspect(Ecto.Changeset.traverse_errors(changeset, &IkeEmailsWeb.CoreComponents.translate_error/1))}"
        )

        System.halt(1)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
