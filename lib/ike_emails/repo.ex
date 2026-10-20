defmodule IkeEmails.Repo do
  use Ecto.Repo,
    otp_app: :ike_emails,
    adapter: Ecto.Adapters.Postgres
end
