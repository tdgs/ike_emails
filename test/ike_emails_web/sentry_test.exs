defmodule IkeEmailsWeb.SentryTest do
  # What Sentry is told about the requests. The context is kept by process, and the
  # requests of ConnTest are made in the process of the test, so it can be read here.
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  alias IkeEmailsWeb.ApiToken

  defp sentry_user, do: Sentry.Context.get_all().user

  # The context of a LiveView is kept by its process, which is not the one of the test.
  # It is in the metadata of the logger, which is in the dictionary of the process
  defp context_of(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    metadata = Keyword.fetch!(dictionary, :"$logger_metadata$")
    sentry = Map.fetch!(metadata, Sentry.Context.__logger_metadata_key__())

    Map.put(sentry, :breadcrumbs, sentry |> Map.get(:breadcrumbs, []) |> Enum.reverse())
  end

  test "is off without a DSN, as it is in the tests" do
    assert Sentry.Config.dsn() == nil
  end

  describe "the logger handler" do
    setup do
      {:ok, %{config: config}} = :logger.get_handler_config(:sentry_handler)
      %{config: config}
    end

    # Bandit logs the exception of a request under its own domain. If the handler
    # leaves it out, as it does by default, the errors of the requests never get to
    # Sentry.
    test "does not leave out what Bandit logs", %{config: config} do
      refute :bandit in config.capture_excluded_domains
    end

    test "reports what is logged as an error", %{config: config} do
      assert config.capture_log_messages
    end
  end

  describe "the user of the errors" do
    test "is the id of the logged in user, and nothing else", %{conn: conn} do
      user = user_fixture()

      conn |> log_in_user(user) |> get(~p"/")

      assert sentry_user() == %{id: user.id}
    end

    test "is the id of the user of the API token" do
      user = user_fixture()

      build_conn()
      |> put_req_header("authorization", "Bearer #{ApiToken.generate(user)}")
      |> post(~p"/api/transactions", %{})

      assert sentry_user() == %{id: user.id}
    end

    # A connection that stays open serves the next request in the same process
    test "is cleared by a request of nobody", %{conn: conn} do
      user = user_fixture()
      conn |> log_in_user(user) |> get(~p"/")
      assert sentry_user() == %{id: user.id}

      get(build_conn(), ~p"/login")

      assert sentry_user() == %{id: nil}
    end
  end

  describe "the request of the errors" do
    # What the bank crawler pushes must stay with us
    test "is there, without its body" do
      user = user_fixture()
      description = "a-description-that-must-not-leave"

      build_conn()
      |> put_req_header("authorization", "Bearer #{ApiToken.generate(user)}")
      |> post(~p"/api/transactions", %{"description" => description})

      context = Sentry.Context.get_all()
      assert context.request.method == "POST"
      refute inspect(context) =~ description
    end
  end

  describe "the context of a LiveView" do
    # What is typed in a form must not leave us. Sentry.LiveViewHook would keep every
    # event with its params as a breadcrumb, and send it with any error of the process
    test "keeps nothing of the forms" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      settings_fixture(scope, %{}, token: nil)
      token = "marker-api-key-3b8d5e6f01"
      password = "marker-password-9a2c4d7e11"

      {:ok, view, _html} = live(log_in_user(build_conn(), user), ~p"/settings")

      # The password is not the one of the user, so that the page stays, and its
      # process with it
      view
      |> form("#elorus-token-form", %{"api_token" => token, "password" => password})
      |> render_submit()

      context = context_of(view.pid)

      assert context.breadcrumbs == []
      refute inspect(context, limit: :infinity) =~ token
      refute inspect(context, limit: :infinity) =~ password
    end

    test "is the id of the user" do
      user = user_fixture()

      {:ok, view, _html} = live(log_in_user(build_conn(), user), ~p"/settings")

      assert context_of(view.pid).user == %{id: user.id}
    end
  end
end
