# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     IkeEmails.Repo.insert!(%IkeEmails.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# A user to log in with in development. Make the others with `mix user.create`.
if Mix.env() == :dev do
  email = "dev@example.com"

  unless IkeEmails.Repo.get_by(IkeEmails.Accounts.User, email: email) do
    {:ok, _user} =
      IkeEmails.Accounts.register_user(%{email: email, password: "dev-password-123"})
  end
end
