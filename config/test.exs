import Config

config :ike_emails, :bank_api_token, "test-bank-api-token"

# Invoice PDFs are kept in memory, see test/support/storage_in_memory.ex
config :ike_emails, IkeEmails.Storage, adapter: IkeEmails.Storage.InMemory

# Elorus requests are answered by Req.Test stubs, see test/ike_emails/elorus_test.exs
config :ike_emails, IkeEmails.Elorus,
  api_token: "test-elorus-token",
  organization_id: "1000000243015421",
  demo: false,
  req_options: [plug: {Req.Test, IkeEmails.Elorus}, retry_delay: 1]

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ike_emails, IkeEmails.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ike_emails_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ike_emails, IkeEmailsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ha7b7FpsRJ7SQ4sHl3+jvNtkDPl5wfIIyjiNDLGeiPYlW+Yira4QWjOd7pcpfOd/",
  server: false

# In test we don't send emails
config :ike_emails, IkeEmails.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
