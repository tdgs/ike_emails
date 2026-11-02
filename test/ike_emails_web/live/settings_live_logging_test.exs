defmodule IkeEmailsWeb.SettingsLiveLoggingTest do
  # The LiveView logs its events as debug, which the tests do not print. Raising the
  # level is global to the VM, so the test that does it is not async: it would print
  # the logs of every test that runs beside it.
  use IkeEmailsWeb.ConnCase, async: false

  # The console prints what is logged at the raised level, even when it is captured
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  require Logger

  # Not an API key, but one that no other text of the page can be mistaken for
  @token "marker-api-key-7c1e9f20b4"

  test "has the key and the password out of what a LiveView logs of the events", %{conn: conn} do
    # Another password than the one of every test, to be found in the log of no other
    password = "a-distinctive-password-4821"
    user = user_fixture(%{password: password})
    scope = user_scope_fixture(user)
    settings_fixture(scope, %{}, token: nil, password: password)
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/settings")

    Logger.put_module_level(Phoenix.LiveView.Logger, :debug)
    on_exit(fn -> Logger.delete_module_level(Phoenix.LiveView.Logger) end)

    log =
      capture_log([level: :debug], fn ->
        view
        |> form("#elorus-token-form", %{"api_token" => @token, "password" => password})
        |> render_submit()
        |> follow_redirect(conn)
      end)

    # The event is logged, so that what is left out of the log is not for lack of it
    assert log =~ "save_token"
    refute log =~ @token
    refute log =~ password
  end
end
