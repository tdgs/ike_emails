defmodule IkeEmails.Settings.AuditLogTest do
  # The log of the API key being set or removed is info, which the tests do not
  # print. Raising the level is global to the VM, so the tests that do it are not
  # async: they would print the logs of every test that runs beside them.
  use IkeEmails.DataCase, async: false

  # The console prints what is logged at the raised level, even when it is captured
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import IkeEmails.Fixtures

  require Logger

  alias IkeEmails.Settings

  @token "an-elorus-api-key-1234"

  setup :create_user_scope

  setup do
    Logger.put_module_level(Settings, :info)
    on_exit(fn -> Logger.delete_module_level(Settings) end)
  end

  describe "set_elorus_token/3" do
    test "logs who did it, and not the token", %{scope: scope} do
      log =
        capture_log([level: :info], fn ->
          Settings.set_elorus_token(scope, @token, valid_user_password())
        end)

      assert log =~ "User #{scope.user.id} set the Elorus API key"
      refute log =~ @token
      refute log =~ valid_user_password()
    end
  end

  describe "clear_elorus_token/1" do
    test "logs who did it, once", %{scope: scope} do
      settings_fixture(scope)

      log = capture_log([level: :info], fn -> Settings.clear_elorus_token(scope) end)
      assert log =~ "User #{scope.user.id} removed the Elorus API key"

      log = capture_log([level: :info], fn -> Settings.clear_elorus_token(scope) end)
      refute log =~ "removed"
    end
  end
end
