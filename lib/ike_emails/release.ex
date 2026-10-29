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
  production, where there is no Mix:

      bin/ike_emails eval 'IkeEmails.Release.create_user("me@example.com", "a long password")'
  """
  def create_user(email, password) do
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
          "Could not create the user: #{inspect(IkeEmails.Accounts.error_messages(changeset))}"
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
