defmodule IkeEmailsWeb.SettingsLiveTest do
  use IkeEmailsWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  alias IkeEmails.Elorus.Connection
  alias IkeEmails.Repo
  alias IkeEmails.Settings
  alias IkeEmails.Settings.UserSettings

  setup :register_and_log_in_user

  # Not an API key, but one that no other text of the page can be mistaken for
  @token "marker-api-key-7c1e9f20b4"

  defp stored(scope), do: Repo.get_by!(UserSettings, user_id: scope.user.id)

  defp settings_form(view, attrs) do
    form(view, "#settings-form", %{"settings" => attrs})
  end

  defp token_form(view, token, password \\ valid_user_password()) do
    form(view, "#elorus-token-form", %{"api_token" => token, "password" => password})
  end

  # Whatever the page holds of the user's secrets, in whatever form
  defp refute_secrets(view, secrets) do
    html = render(view)
    assigns = inspect(:sys.get_state(view.pid).socket.assigns, limit: :infinity)

    for secret <- secrets do
      refute html =~ secret
      refute assigns =~ secret
    end
  end

  describe "the page" do
    test "has the forms, empty, for a user with no settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#settings-form")
      assert has_element?(view, "#settings-business-name:not([value])")
      assert has_element?(view, "#settings-business-vat:not([value])")
      assert has_element?(view, "#settings-elorus-organization-id:not([value])")
      assert has_element?(view, "#elorus-token-form")
      assert has_element?(view, "#elorus-token-status", "No key")
      refute has_element?(view, "#clear-elorus-token")
    end

    test "has the settings of the user", %{conn: conn, scope: scope} do
      settings_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#settings-business-name[value='Test Business']")
      assert has_element?(view, "#settings-business-vat[value='EL099999999']")
      assert has_element?(view, "#settings-elorus-organization-id[value='1000000243015421']")
      assert has_element?(view, "#elorus-token-status", "Key saved")
      assert has_element?(view, "#clear-elorus-token")
    end

    test "has not the settings of other users", %{conn: conn, scope: scope} do
      settings_fixture(scope, %{business_name: "Mine"})
      theirs = user_scope_fixture()
      settings_fixture(theirs, %{business_name: "Theirs", elorus_organization_id: "99887766"})

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#settings-business-name[value='Mine']")
      refute has_element?(view, "#settings-elorus-organization-id[value='99887766']")
      refute render(view) =~ "Theirs"
    end

    test "is in the navigation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#nav-settings") |> render_click()

      assert_redirect(view, ~p"/settings")
    end

    test "is the page that the navigation shows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#nav-settings.bg-base-200")
      refute has_element?(view, "#nav-invoices.bg-base-200")
    end

    test "sends whoever is not logged in to the login" do
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/settings")
    end
  end

  describe "saving the settings" do
    test "keeps the business and the organization", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> settings_form(%{
        "business_name" => "  Acme Ltd ",
        "business_vat" => "el 123.456.789",
        "elorus_organization_id" => "5550001"
      })
      |> render_submit()

      assert has_element?(view, "#flash-info")
      assert Settings.business(scope) == %{name: "Acme Ltd", vat: "EL123456789"}
      assert stored(scope).elorus_organization_id == "5550001"
      assert has_element?(view, "#settings-business-name[value='Acme Ltd']")
    end

    test "keeps the demo flag", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> settings_form(%{"elorus_demo" => "true"}) |> render_submit()

      assert stored(scope).elorus_demo
      assert has_element?(view, "#settings-elorus-demo[checked]")
    end

    test "says what is wrong, and keeps nothing", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> settings_form(%{
        "business_name" => "Line\nbreak",
        "elorus_organization_id" => "not an id!"
      })
      |> render_submit()

      assert has_element?(view, "#settings-form .text-error")
      refute has_element?(view, "#flash-info")
      assert Repo.aggregate(UserSettings, :count) == 0
      assert Settings.business(scope) == nil
    end

    test "leaves the API key as it is", %{conn: conn, scope: scope} do
      settings_fixture(scope)
      sealed = stored(scope).elorus_token_sealed
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> settings_form(%{"business_name" => "Renamed"}) |> render_submit()

      assert stored(scope).elorus_token_sealed == sealed
      assert has_element?(view, "#elorus-token-status", "Key saved")
    end

    test "locks the API key when the organization changes, and not otherwise", %{
      conn: conn,
      scope: scope
    } do
      settings_fixture(scope)
      :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
      on_exit(fn -> Connection.lock(scope) end)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> settings_form(%{"business_name" => "Renamed"}) |> render_submit()
      assert Connection.unlocked?(scope)

      view |> settings_form(%{"elorus_organization_id" => "777"}) |> render_submit()
      refute Connection.unlocked?(scope)
    end

    test "does not touch the settings of other users", %{conn: conn} do
      theirs = user_scope_fixture()
      settings_fixture(theirs, %{business_name: "Theirs"})
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> settings_form(%{"business_name" => "Mine"}) |> render_submit()

      assert Settings.business(theirs) == %{name: "Theirs", vat: "EL099999999"}
    end
  end

  describe "the API key form" do
    test "has the names that the logs filter, and is not validated as it is typed", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#elorus-token-form[phx-submit='save_token']")
      refute has_element?(view, "#elorus-token-form[phx-change]")
      assert has_element?(view, "#settings-api-token[type=password][name=api_token][value='']")
      assert has_element?(view, "#settings-password[type=password][name=password][value='']")
      refute has_element?(view, "#elorus-token-form input[name*='[']")
      # It is a form of its own, and not a part of the one of the settings
      refute has_element?(view, "#settings-form #elorus-token-form")
      refute has_element?(view, "#settings-form input[type=password]")
    end

    test "seals the key with the password, and shows it is saved", %{conn: conn, scope: scope} do
      settings_fixture(scope, %{}, token: nil)
      {:ok, view, _html} = live(conn, ~p"/settings")

      {:ok, view, _html} =
        view |> token_form(@token) |> render_submit() |> follow_redirect(conn, ~p"/settings")

      assert has_element?(view, "#flash-info")
      assert has_element?(view, "#elorus-token-status", "Key saved")
      assert has_element?(view, "#clear-elorus-token")
      assert Settings.elorus_configured?(scope)

      assert {:ok, credentials} =
               Settings.unseal_elorus_credentials(scope, valid_user_password())

      assert credentials.api_token == @token

      assert "1.XCP." <> _ciphertext = sealed = stored(scope).elorus_token_sealed
      refute sealed =~ @token
    end

    test "takes the key without the spaces around it", %{conn: conn, scope: scope} do
      settings_fixture(scope, %{}, token: nil)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> token_form("  #{@token}\n") |> render_submit() |> follow_redirect(conn)

      assert {:ok, %{api_token: @token}} =
               Settings.unseal_elorus_credentials(scope, valid_user_password())
    end

    test "is empty again when it is saved", %{conn: conn, scope: scope} do
      settings_fixture(scope, %{}, token: nil)
      {:ok, view, _html} = live(conn, ~p"/settings")

      {:ok, view, _html} =
        view |> token_form(@token) |> render_submit() |> follow_redirect(conn)

      assert has_element?(view, "#settings-api-token[value='']")
      assert has_element?(view, "#settings-password[value='']")
      refute has_element?(view, "#elorus-token-error")
      refute_secrets(view, [@token, valid_user_password()])
    end

    test "replaces the key there was, and locks it", %{conn: conn, scope: scope} do
      settings_fixture(scope)
      :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
      on_exit(fn -> Connection.lock(scope) end)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> token_form(@token) |> render_submit() |> follow_redirect(conn)

      refute Connection.unlocked?(scope)

      assert {:ok, %{api_token: @token}} =
               Settings.unseal_elorus_credentials(scope, valid_user_password())
    end

    test "needs the password of the user", %{conn: conn, scope: scope} do
      settings_fixture(scope, %{}, token: nil)
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> token_form(@token, "not the right password") |> render_submit()

      assert html =~ "elorus-token-error"
      assert has_element?(view, "#elorus-token-error")
      assert has_element?(view, "#elorus-token-status", "No key")
      refute Settings.elorus_configured?(scope)
      assert stored(scope).elorus_token_sealed == nil
      refute_secrets(view, [@token, "not the right password"])
    end

    test "keeps the key there was when the password is wrong", %{conn: conn, scope: scope} do
      settings_fixture(scope)
      sealed = stored(scope).elorus_token_sealed
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> token_form(@token, "not the right password") |> render_submit()

      assert has_element?(view, "#elorus-token-error")
      assert stored(scope).elorus_token_sealed == sealed
    end

    test "does not take what is not an API key", %{conn: conn, scope: scope} do
      settings_fixture(scope, %{}, token: nil)
      {:ok, view, _html} = live(conn, ~p"/settings")

      for bad <- ["a-key\nwith-a-line-break", "short", "has spaces in it", "naïve-key-123456"] do
        view |> token_form(bad) |> render_submit()

        assert has_element?(view, "#elorus-token-error")
        refute Settings.elorus_configured?(scope)
        refute_secrets(view, [bad])
      end
    end

    test "is not shown the key or the password, in any state", %{conn: conn, scope: scope} do
      settings_fixture(scope, %{}, token: nil)
      password = valid_user_password()
      secrets = [@token, password]
      {:ok, view, _html} = live(conn, ~p"/settings")

      # A wrong password
      view |> token_form(@token, "not the right password") |> render_submit()
      refute_secrets(view, [@token, "not the right password"])

      # A key that is not one
      view |> token_form("short") |> render_submit()
      refute_secrets(view, ["short"])

      # A failed validation of the settings
      view |> settings_form(%{"business_name" => "Line\nbreak"}) |> render_submit()
      assert has_element?(view, "#settings-form .text-error")
      refute_secrets(view, secrets)

      # A key that is saved
      {:ok, view, _html} = view |> token_form(@token) |> render_submit() |> follow_redirect(conn)
      refute_secrets(view, secrets)

      # A key that is removed
      view |> element("#clear-elorus-token") |> render_click()
      refute_secrets(view, secrets)
    end

    test "is answered, not crashed, by what it was not meant to get", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_hook(view, "save_token", %{"api_token" => @token})

      assert has_element?(view, "#elorus-token-error")
      refute Settings.elorus_configured?(scope)
      refute_secrets(view, [@token])
    end

    test "does not touch the key of other users", %{conn: conn, scope: scope} do
      theirs = user_scope_fixture()
      settings_fixture(theirs)
      sealed = stored(theirs).elorus_token_sealed
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> token_form(@token) |> render_submit() |> follow_redirect(conn)

      assert stored(theirs).elorus_token_sealed == sealed

      assert {:ok, %{api_token: "test-elorus-token"}} =
               Settings.unseal_elorus_credentials(theirs, valid_user_password())

      assert stored(scope).elorus_token_sealed != sealed
    end
  end

  describe "removing the API key" do
    setup %{scope: scope} do
      settings_fixture(scope)
      :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
      on_exit(fn -> Connection.lock(scope) end)
    end

    test "forgets it, and locks it", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert Connection.unlocked?(scope)

      view |> element("#clear-elorus-token") |> render_click()

      assert has_element?(view, "#elorus-token-status", "No key")
      refute has_element?(view, "#clear-elorus-token")
      assert has_element?(view, "#flash-info")
      refute Settings.elorus_configured?(scope)
      refute Connection.unlocked?(scope)
      assert stored(scope).elorus_token_sealed == nil
      assert stored(scope).elorus_token_salt == nil
    end

    test "asks to be sure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#clear-elorus-token[data-confirm]")
    end

    test "leaves the business and the organization", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#clear-elorus-token") |> render_click()

      assert Settings.business(scope) == %{name: "Test Business", vat: "EL099999999"}
      assert stored(scope).elorus_organization_id == "1000000243015421"
      assert has_element?(view, "#settings-business-name[value='Test Business']")
    end

    test "leaves the key of other users", %{conn: conn} do
      theirs = user_scope_fixture()
      settings_fixture(theirs)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#clear-elorus-token") |> render_click()

      assert Settings.elorus_configured?(theirs)
    end
  end

  describe "what is logged" do
    # The params of a request, and of the events of a LiveView, are logged with what
    # these filters leave of them
    test "leaves out the password and the API key, with the names the form has" do
      params = %{"api_token" => @token, "password" => valid_user_password(), "other" => "kept"}

      assert Phoenix.Logger.filter_values(params) ==
               %{"api_token" => "[FILTERED]", "password" => "[FILTERED]", "other" => "kept"}
    end

    # It is how the events are sent to the server, and how they appear in the report
    # of a crash
    test "leaves out the form as it is sent by the browser" do
      value = URI.encode_query(%{"api_token" => @token, "password" => valid_user_password()})
      message = %{"type" => "form", "event" => "save_token", "value" => value}

      assert Phoenix.Logger.filter_values(message)["value"] == "[FILTERED]"
    end

    # A name that is not top level is not matched by what is sent, which is why the
    # fields of the form have none
    test "does not leave out the form of a nested name" do
      value = URI.encode_query(%{"settings[api_token]" => @token})

      refute Phoenix.Logger.filter_values(%{"value" => value})["value"] == "[FILTERED]"
    end

    test "has the key and the password out of the report of a crash", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      # The user is gone, so that the key cannot be stored and the view crashes
      Repo.delete!(user)
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          catch_exit(view |> token_form(@token) |> render_submit())
          assert_receive {:EXIT, _pid, {%Ecto.ConstraintError{}, _stacktrace}}
        end)

      # It is reported, with the message that made it, as filtered
      assert log =~ "save_token"
      assert log =~ "[FILTERED]"
      refute log =~ @token
      refute log =~ valid_user_password()
    end
  end
end
