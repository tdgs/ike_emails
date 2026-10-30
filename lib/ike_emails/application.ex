defmodule IkeEmails.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    add_sentry_handler()

    children = [
      IkeEmailsWeb.Telemetry,
      IkeEmails.Repo,
      {DNSCluster, query: Application.get_env(:ike_emails, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IkeEmails.PubSub},
      # Runs the slow calls (to Elorus) away from the LiveViews that wait for them
      {Task.Supervisor, name: IkeEmails.TaskSupervisor},
      # Start a worker by calling: IkeEmails.Worker.start_link(arg)
      # {IkeEmails.Worker, arg},
      # Start to serve requests, typically the last entry
      IkeEmailsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: IkeEmails.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Reports to Sentry what is logged as an error and the crashes of processes, such as
  # a LiveView or a task. It does nothing without SENTRY_DSN.
  #
  # Bandit logs the exception of a request under its own domain, which the handler
  # leaves out by default, so only Cowboy is left out: without this the errors of the
  # requests are not reported at all.
  defp add_sentry_handler do
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
      config: %{
        capture_log_messages: true,
        capture_excluded_domains: [:cowboy]
      }
    })
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IkeEmailsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
