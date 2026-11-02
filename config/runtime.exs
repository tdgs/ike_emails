import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ike_emails start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ike_emails, IkeEmailsWeb.Endpoint, server: true
end

# Reading the PDF of an invoice with a language model is optional: without
# AI_MODEL the feature is off. AI_MODEL is a provider and a model, such as
# anthropic:claude-sonnet-5-5 or openai:gpt-5, and the provider's own API key
# must be set too, such as ANTHROPIC_API_KEY or OPENAI_API_KEY. The PDF is sent
# to that provider. The tests have their own, see config/test.exs.
ai_model = System.get_env("AI_MODEL")

if config_env() != :test and ai_model not in [nil, ""] do
  config :ike_emails, IkeEmails.InvoiceExtractor, model: ai_model
end

# Reporting the errors to Sentry is optional: without SENTRY_DSN it is off. The DSN
# is found in the settings of the project in Sentry. The release is the commit
# that Kamal deployed. The tests never report.
#
# Every call to Elorus and to the language model is traced, so all the traces are
# kept. Only those two make spans, see IkeEmails.Tracing. The spans are made with
# OpenTelemetry, and Sentry's processor and sampler turn them into traces.
sentry_dsn = System.get_env("SENTRY_DSN")

if config_env() != :test and sentry_dsn not in [nil, ""] do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: config_env(),
    release: System.get_env("KAMAL_VERSION"),
    traces_sample_rate: 1.0

  config :opentelemetry,
    span_processor: {Sentry.OpenTelemetry.SpanProcessor, []},
    sampler: {Sentry.OpenTelemetry.Sampler, []}
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ike_emails, IkeEmails.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # The key that seals the Elorus API keys of the users, see
  # IkeEmails.Settings.SealedToken: 32 random bytes in base64, made with
  # `openssl rand -base64 32`. It is not derived from SECRET_KEY_BASE, which can be
  # changed without losing anything. Changing this one makes the users enter their
  # API keys again. The value is never printed.
  settings_encryption_key =
    case "SETTINGS_ENCRYPTION_KEY" |> System.get_env("") |> String.trim() |> Base.decode64() do
      {:ok, key} when byte_size(key) == 32 ->
        key

      _ ->
        raise """
        environment variable SETTINGS_ENCRYPTION_KEY is missing, or is not 32 bytes in base64.
        You can generate one by calling: openssl rand -base64 32
        """
    end

  config :ike_emails, IkeEmails.Settings.SealedToken, keys: [{"1", settings_encryption_key}]

  config :ike_emails, IkeEmails.Storage.S3,
    bucket:
      System.get_env("S3_BUCKET") ||
        raise("environment variable S3_BUCKET is missing, the bucket for the invoice PDFs."),
    region: System.get_env("AWS_REGION") || "us-east-1",
    # Only for S3-compatible servers, AWS needs none
    endpoint_url: System.get_env("AWS_ENDPOINT_URL_S3"),
    access_key_id:
      System.get_env("AWS_ACCESS_KEY_ID") ||
        raise("environment variable AWS_ACCESS_KEY_ID is missing."),
    secret_access_key:
      System.get_env("AWS_SECRET_ACCESS_KEY") ||
        raise("environment variable AWS_SECRET_ACCESS_KEY is missing.")

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ike_emails, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ike_emails, IkeEmailsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ike_emails, IkeEmailsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ike_emails, IkeEmailsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :ike_emails, IkeEmails.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
