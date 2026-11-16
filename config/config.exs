# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ike_emails,
  ecto_repos: [IkeEmails.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :ike_emails, IkeEmailsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: IkeEmailsWeb.ErrorHTML, json: IkeEmailsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: IkeEmails.PubSub,
  live_view: [signing_salt: "d7nq+Ax8"]

# What is left out of the logs: the values of the params with these in their name.
# This is the default, said here since the password and the API key of Elorus that
# are typed in at /settings depend on it (they are the top level params `password`
# and `api_token`)
config :phoenix, :filter_parameters, ["password", "token"]

# Invoice PDFs are stored in S3 (SeaweedFS locally, see compose.yaml)
config :ike_emails, IkeEmails.Storage, adapter: IkeEmails.Storage.S3

config :ike_emails, IkeEmails.Storage.S3,
  bucket: "ike-emails-invoices",
  region: "us-east-1"

# The spans of the calls to Elorus and the language model go to Sentry, see
# config/runtime.exs. Without SENTRY_DSN they go nowhere, and OpenTelemetry does
# not look for a collector on localhost.
config :opentelemetry, traces_exporter: :none

# The Elorus API, where the invoices for income are issued. Only its address is
# here: the API key and the organization are those of each user, kept in their
# settings (see IkeEmails.Settings)
config :ike_emails, IkeEmails.Elorus, base_url: "https://api.elorus.com"

# The API key of Elorus of a user is sealed with a key of the server and the
# password of the user, see IkeEmails.Settings.SealedToken. The key of the server
# comes from the environment, see config/runtime.exs. The iterations of PBKDF2 are
# to take 200 to 500 ms on the server
config :ike_emails, IkeEmails.Settings.SealedToken, iterations: 600_000

# The key is unlocked in a process of its own, which is gone when it was not used
# for this long, see IkeEmails.Elorus.Connection
config :ike_emails, IkeEmails.Elorus.Connection, idle_timeout: :timer.minutes(15)

# Reading invoice PDFs with a language model is optional, and the model is set
# by the environment, see config/runtime.exs
config :ike_emails, IkeEmails.InvoiceExtractor,
  client: IkeEmails.InvoiceExtractor.Client.ReqLLM,
  model: nil

# Proposing matches for the transactions of a month is optional too, and uses the
# same model, see IkeEmails.MonthClose
config :ike_emails, IkeEmails.MonthClose, model: nil

# The bank is reached with a browser that logs in to myAlpha, see IkeEmails.Bank.Driver
config :ike_emails, IkeEmails.Bank, driver: IkeEmails.Bank.Driver.Chrome

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ike_emails, IkeEmails.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ike_emails: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  ike_emails: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
