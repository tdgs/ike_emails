import Config

# Hash passwords with the least work, the tests make many users
config :bcrypt_elixir, log_rounds: 1

# Invoice PDFs are kept in memory, see test/support/storage_in_memory.ex
config :ike_emails, IkeEmails.Storage, adapter: IkeEmails.Storage.InMemory

# Elorus requests are answered by Req.Test stubs, see test/ike_emails/elorus_test.exs.
# The API key and the organization are those of a user, see IkeEmails.Fixtures
config :ike_emails, IkeEmails.Elorus,
  req_options: [plug: {Req.Test, IkeEmails.Elorus}, retry_delay: 1]

# Sealing a key takes the least work, and the server key is not a secret
config :ike_emails, IkeEmails.Settings.SealedToken,
  keys: [{"1", Base.decode64!("1rQ9SbonkzPiLm37lnbmEk4HkTvrLd/73bYsXviJONQ=")}],
  iterations: 1_000

# Invoices are read by a stub, see test/support/invoice_extractor_stub.ex
config :ike_emails, IkeEmails.InvoiceExtractor,
  client: IkeEmails.InvoiceExtractorStub,
  model: "test:model"

# The month-close agent calls ReqLLM, and the tests answer its requests, see
# test/support/llm_stub.ex
config :ike_emails, IkeEmails.MonthClose, model: "anthropic:claude-sonnet-5-5"

# The bank is answered by a scripted driver, see test/support/bank_driver_stub.ex
config :ike_emails, IkeEmails.Bank, driver: IkeEmails.BankDriverStub

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

# The spans of the calls to Elorus and the language model are sent to the test that
# makes them, see test/support/span_collector.ex
config :opentelemetry, processors: [{:otel_simple_processor, %{}}]
