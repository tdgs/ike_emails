defmodule IkeEmailsWeb.SentryTest do
  # What Sentry is told about the requests. The context is kept by process, and the
  # requests of ConnTest are made in the process of the test, so it can be read here.
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmailsWeb.ApiToken

  defp sentry_user, do: Sentry.Context.get_all().user

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
end
