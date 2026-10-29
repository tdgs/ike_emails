defmodule IkeEmailsWeb.Router do
  use IkeEmailsWeb, :router

  import IkeEmailsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IkeEmailsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug IkeEmailsWeb.Plugs.ApiAuth
  end

  scope "/", IkeEmailsWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/login", SessionController, :new
  end

  scope "/", IkeEmailsWeb do
    pipe_through :browser

    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  scope "/", IkeEmailsWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{IkeEmailsWeb.UserAuth, :require_authenticated}] do
      live "/", ReconciliationLive, :index
      live "/transactions/:id/invoice", ReconciliationLive, :attach

      live "/invoices", InvoiceLive.Index, :index
      live "/invoices/new", InvoiceLive.Index, :new
      live "/invoices/:id/edit", InvoiceLive.Index, :edit
    end

    get "/invoices/:id/pdf", InvoicePdfController, :show
  end

  # The bank crawler logs in with the email and password of a user, and pushes
  # that user's transactions with the token it gets
  scope "/api", IkeEmailsWeb do
    pipe_through :api

    post "/auth/token", ApiTokenController, :create
  end

  scope "/api", IkeEmailsWeb do
    pipe_through [:api, :api_auth]

    post "/transactions", TransactionController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ike_emails, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: IkeEmailsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
