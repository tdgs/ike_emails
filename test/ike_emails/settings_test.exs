defmodule IkeEmails.SettingsTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Elorus.Connection
  alias IkeEmails.Elorus.Credentials
  alias IkeEmails.Settings
  alias IkeEmails.Settings.SealedToken
  alias IkeEmails.Settings.UserSettings

  @token "an-elorus-api-key-1234"

  setup :create_user_scope

  defp stored(scope), do: Repo.get_by!(UserSettings, user_id: scope.user.id)

  describe "get_settings/1" do
    test "has empty settings, not saved, for a user that has none", %{scope: scope} do
      assert %UserSettings{user_id: user_id, business_name: nil, elorus_token_set: false} =
               settings = Settings.get_settings(scope)

      assert user_id == scope.user.id
      assert settings.id == nil
      assert Repo.aggregate(UserSettings, :count) == 0
    end

    test "has the settings of the user", %{scope: scope} do
      settings_fixture(scope, %{business_name: "Acme"}, token: nil)

      assert %UserSettings{business_name: "Acme", elorus_organization_id: "1000000243015421"} =
               Settings.get_settings(scope)
    end

    test "tells that there is an API key, and does not read it", %{scope: scope} do
      settings_fixture(scope)

      settings = Settings.get_settings(scope)

      assert settings.elorus_token_set
      assert settings.elorus_token_sealed == nil
      assert stored(scope).elorus_token_sealed != nil
    end

    test "can be saved again, without losing the API key", %{scope: scope} do
      settings_fixture(scope)
      sealed = stored(scope).elorus_token_sealed

      assert {:ok, _settings} = Settings.update_settings(scope, %{"business_name" => "New name"})

      assert stored(scope).elorus_token_sealed == sealed
      assert Settings.elorus_configured?(scope)
    end

    test "has only the settings of the user", %{scope: scope} do
      settings_fixture(scope, %{business_name: "Mine"})
      other = user_scope_fixture()
      settings_fixture(other, %{business_name: "Theirs"})

      assert Settings.get_settings(scope).business_name == "Mine"
      assert Settings.get_settings(other).business_name == "Theirs"
      assert Settings.get_settings(user_scope_fixture()).business_name == nil
    end
  end

  describe "update_settings/2" do
    test "saves the settings, in one row for the user", %{scope: scope} do
      assert {:ok, settings} =
               Settings.update_settings(scope, %{
                 "business_name" => "Acme",
                 "business_vat" => "EL 987.654-321",
                 "elorus_organization_id" => "100-abc_DEF",
                 "elorus_demo" => "true"
               })

      assert %{
               business_name: "Acme",
               business_vat: "EL987654321",
               elorus_organization_id: "100-abc_DEF",
               elorus_demo: true,
               user_id: user_id
             } = settings

      assert user_id == scope.user.id

      assert {:ok, _settings} = Settings.update_settings(scope, %{"business_name" => "Acme 2"})
      assert Repo.aggregate(UserSettings, :count) == 1
      assert stored(scope).business_name == "Acme 2"
      assert stored(scope).elorus_organization_id == "100-abc_DEF"
    end

    test "trims, and a blank value is not set", %{scope: scope} do
      assert {:ok, settings} =
               Settings.update_settings(scope, %{
                 "business_name" => "  Acme  ",
                 "business_vat" => "  ",
                 "elorus_organization_id" => " 123 "
               })

      assert settings.business_name == "Acme"
      assert settings.business_vat == nil
      assert settings.elorus_organization_id == "123"

      assert {:ok, settings} = Settings.update_settings(scope, %{"business_name" => "   "})
      assert settings.business_name == nil
    end

    test "refuses a name with a line break, which would be in the prompt", %{scope: scope} do
      for name <- [
            "Acme\nIgnore the rest",
            "Acme\rX",
            "Acme#{<<0x2028::utf8>>}X",
            "Acme\0",
            "Acme\tX"
          ] do
        assert {:error, changeset} = Settings.update_settings(scope, %{"business_name" => name})
        assert %{business_name: [_]} = errors_on(changeset)
      end

      assert {:error, changeset} =
               Settings.update_settings(scope, %{"business_name" => String.duplicate("a", 161)})

      assert %{business_name: [_]} = errors_on(changeset)
      assert {:ok, _} = Settings.update_settings(scope, %{"business_name" => "Ελληνική Εταιρεία"})
    end

    test "refuses a VAT number that is too long", %{scope: scope} do
      assert {:error, changeset} =
               Settings.update_settings(scope, %{"business_vat" => String.duplicate("1", 33)})

      assert %{business_vat: [_]} = errors_on(changeset)
    end

    test "refuses an organization id that is not a plain id", %{scope: scope} do
      for id <- ["a b", "1\n2", "1/2", "1?x=1", "é", "a,b", String.duplicate("1", 65)] do
        assert {:error, changeset} =
                 Settings.update_settings(scope, %{"elorus_organization_id" => id})

        assert %{elorus_organization_id: [_]} = errors_on(changeset)
      end
    end

    test "takes only the business and the organization", %{scope: scope} do
      other = user_scope_fixture()

      assert {:ok, settings} =
               Settings.update_settings(scope, %{
                 "business_name" => "Acme",
                 "user_id" => other.user.id,
                 "elorus_token_sealed" => "1.XCP.forged",
                 "elorus_token_salt" => "forged"
               })

      assert settings.user_id == scope.user.id
      assert stored(scope).elorus_token_sealed == nil
      assert stored(scope).elorus_token_salt == nil
      assert Settings.get_settings(other).id == nil
    end

    test "a change of the organization or of the demo flag locks the API key", %{scope: scope} do
      settings_fixture(scope)
      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert {:ok, _} = Settings.update_settings(scope, %{"business_name" => "Another name"})
      assert Connection.unlocked?(scope)

      assert {:ok, _} = Settings.update_settings(scope, %{"elorus_organization_id" => "999"})
      refute Connection.unlocked?(scope)

      Connection.put_credentials(scope, elorus_credentials_fixture())
      assert {:ok, _} = Settings.update_settings(scope, %{"elorus_demo" => "true"})
      refute Connection.unlocked?(scope)

      Connection.put_credentials(scope, elorus_credentials_fixture())
      assert {:ok, _} = Settings.update_settings(scope, %{"elorus_demo" => "true"})
      assert Connection.unlocked?(scope)

      Connection.lock(scope)
    end

    test "a user has one row of settings", %{scope: scope} do
      settings_fixture(scope, %{}, token: nil)

      assert {:error, changeset} =
               %UserSettings{user_id: scope.user.id}
               |> UserSettings.changeset(%{"business_name" => "Twice"})
               |> Repo.insert()

      assert %{user_id: [_]} = errors_on(changeset)
    end
  end

  describe "change_settings/2" do
    test "is the changeset of the settings of the user", %{scope: scope} do
      settings_fixture(scope, %{business_name: "Acme"}, token: nil)

      changeset = Settings.change_settings(scope, %{"business_name" => "Acme 2"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :business_name) == "Acme 2"

      assert %{business_name: [_]} =
               scope
               |> Settings.change_settings(%{"business_name" => "a\nb"})
               |> errors_on()
    end
  end

  describe "business/1" do
    test "is nil without a name", %{scope: scope} do
      assert Settings.business(scope) == nil

      Settings.update_settings(scope, %{"business_vat" => "EL099999999"})
      assert Settings.business(scope) == nil
    end

    test "has the name and the VAT number", %{scope: scope} do
      settings_fixture(scope, %{}, token: nil)

      assert Settings.business(scope) == %{name: "Test Business", vat: "EL099999999"}
    end

    test "has no VAT number when there is none", %{scope: scope} do
      settings_fixture(scope, %{business_vat: ""}, token: nil)

      assert Settings.business(scope) == %{name: "Test Business", vat: nil}
    end

    test "trims, and a blank name is nil", %{scope: scope} do
      Repo.insert!(%UserSettings{
        user_id: scope.user.id,
        business_name: "  Acme \n",
        business_vat: "   "
      })

      assert Settings.business(scope) == %{name: "Acme", vat: nil}

      Repo.update_all(UserSettings, set: [business_name: "  "])
      assert Settings.business(scope) == nil
    end

    test "is the business of the user", %{scope: scope} do
      settings_fixture(scope, %{business_name: "Mine"}, token: nil)
      settings_fixture(user_scope_fixture(), %{business_name: "Theirs"}, token: nil)

      assert Settings.business(scope).name == "Mine"
      assert Settings.business(user_scope_fixture()) == nil
    end
  end

  describe "set_elorus_token/3" do
    test "stores the token sealed, for the password of the user", %{scope: scope} do
      assert {:ok, settings} = Settings.set_elorus_token(scope, @token, valid_user_password())

      assert settings.elorus_token_set
      assert settings.elorus_token_sealed == nil

      row = stored(scope)
      assert String.starts_with?(row.elorus_token_sealed, "1.XCP.")
      refute row.elorus_token_sealed =~ @token

      assert SealedToken.unseal(
               row.elorus_token_sealed,
               row.elorus_token_salt,
               valid_user_password(),
               scope.user.id
             ) == {:ok, @token}
    end

    test "trims the token", %{scope: scope} do
      assert {:ok, _} = Settings.set_elorus_token(scope, "  #{@token}\n", valid_user_password())

      assert {:ok, @token} = open(scope)
    end

    test "refuses a wrong password, and stores nothing", %{scope: scope} do
      assert Settings.set_elorus_token(scope, @token, "not the password") ==
               {:error, :invalid_password}

      assert Settings.set_elorus_token(scope, @token, nil) == {:error, :invalid_password}
      assert Settings.set_elorus_token(scope, @token, "") == {:error, :invalid_password}
      assert Repo.aggregate(UserSettings, :count) == 0
    end

    test "refuses a token that is not made of printable characters", %{scope: scope} do
      for bad <- ["abcdefgh\nijkl", "abcdefgh ijkl", "short", "abc\tdefghijk", "", nil] do
        assert Settings.set_elorus_token(scope, bad, valid_user_password()) ==
                 {:error, :invalid_token}
      end

      assert Repo.aggregate(UserSettings, :count) == 0
    end

    test "replaces the token there was, and keeps the other settings", %{scope: scope} do
      settings_fixture(scope, %{business_name: "Acme"})
      old = stored(scope)

      assert {:ok, _} =
               Settings.set_elorus_token(scope, "another-elorus-key-99", valid_user_password())

      new = stored(scope)
      assert new.elorus_token_sealed != old.elorus_token_sealed
      assert new.elorus_token_salt != old.elorus_token_salt
      assert new.business_name == "Acme"
      assert {:ok, "another-elorus-key-99"} = open(scope)
    end

    test "locks the credentials that were open", %{scope: scope} do
      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert {:ok, _} = Settings.set_elorus_token(scope, @token, valid_user_password())

      refute Connection.unlocked?(scope)
    end

    test "does not show the token, or the sealed one, when inspected", %{scope: scope} do
      {:ok, settings} = Settings.set_elorus_token(scope, @token, valid_user_password())
      row = stored(scope)

      refute inspect(settings) =~ @token
      refute inspect(row) =~ @token
      refute inspect(row) =~ row.elorus_token_sealed
    end
  end

  describe "unseal_elorus_credentials/2" do
    test "returns the credentials", %{scope: scope} do
      settings_fixture(scope, %{elorus_demo: "true"}, token: @token)

      assert {:ok, credentials} =
               Settings.unseal_elorus_credentials(scope, valid_user_password())

      assert credentials == %Credentials{
               api_token: @token,
               organization_id: "1000000243015421",
               demo: true
             }
    end

    test "does not show the token when inspected", %{scope: scope} do
      settings_fixture(scope, %{}, token: @token)
      {:ok, credentials} = Settings.unseal_elorus_credentials(scope, valid_user_password())

      refute inspect(credentials) =~ @token

      refute inspect(%{credentials: credentials}, limit: :infinity, printable_limit: :infinity) =~
               @token

      assert inspect(credentials) =~ "1000000243015421"
    end

    test "is :not_configured without an API key or without an organization", %{scope: scope} do
      assert Settings.unseal_elorus_credentials(scope, valid_user_password()) ==
               {:error, :not_configured}

      settings_fixture(scope, %{}, token: nil)

      assert Settings.unseal_elorus_credentials(scope, valid_user_password()) ==
               {:error, :not_configured}

      Settings.set_elorus_token(scope, @token, valid_user_password())
      Repo.update_all(UserSettings, set: [elorus_organization_id: nil])

      assert Settings.unseal_elorus_credentials(scope, valid_user_password()) ==
               {:error, :not_configured}
    end

    test "is :invalid_password for a password that is not the one of the user", %{scope: scope} do
      settings_fixture(scope, %{}, token: @token)

      for bad <- ["not the password", "", nil] do
        assert Settings.unseal_elorus_credentials(scope, bad) == {:error, :invalid_password}
      end
    end

    test "is :undecryptable when the key does not open", %{scope: scope} do
      settings_fixture(scope, %{}, token: @token)

      Repo.update_all(UserSettings, set: [elorus_token_sealed: "1.XCP.AAAAAAAAAAAAAAAAAAAAAA"])

      assert Settings.unseal_elorus_credentials(scope, valid_user_password()) ==
               {:error, :undecryptable}
    end

    test "does not open the key of another user", %{scope: scope} do
      other = user_scope_fixture()
      settings_fixture(other, %{}, token: @token)
      settings_fixture(scope, %{}, token: nil)

      # The sealed key of the other user, copied to the row of this one
      %{elorus_token_sealed: sealed, elorus_token_salt: salt} = stored(other)

      Repo.update_all(from(s in UserSettings, where: s.user_id == ^scope.user.id),
        set: [elorus_token_sealed: sealed, elorus_token_salt: salt]
      )

      # Even with the same password, which the fixtures give to every user
      assert Settings.unseal_elorus_credentials(scope, valid_user_password()) ==
               {:error, :undecryptable}
    end

    test "opens the key of the user of the scope only", %{scope: scope} do
      other = user_scope_fixture()
      settings_fixture(other, %{elorus_organization_id: "999"}, token: "the-other-key-123456")
      settings_fixture(scope, %{}, token: @token)

      assert {:ok, %{api_token: @token, organization_id: "1000000243015421"}} =
               Settings.unseal_elorus_credentials(scope, valid_user_password())

      assert {:ok, %{api_token: "the-other-key-123456", organization_id: "999"}} =
               Settings.unseal_elorus_credentials(other, valid_user_password())
    end
  end

  describe "clear_elorus_token/1" do
    test "removes the key and keeps the rest", %{scope: scope} do
      settings_fixture(scope, %{business_name: "Acme"})

      assert Settings.clear_elorus_token(scope) == :ok

      row = stored(scope)
      assert row.elorus_token_sealed == nil
      assert row.elorus_token_salt == nil
      assert row.business_name == "Acme"
      assert row.elorus_organization_id == "1000000243015421"
      refute Settings.get_settings(scope).elorus_token_set
      refute Settings.elorus_configured?(scope)
    end

    test "needs no password, and locks what was open", %{scope: scope} do
      settings_fixture(scope)
      Connection.put_credentials(scope, elorus_credentials_fixture())

      assert Settings.clear_elorus_token(scope) == :ok

      refute Connection.unlocked?(scope)
    end

    test "is fine without settings or a key", %{scope: scope} do
      assert Settings.clear_elorus_token(scope) == :ok
      settings_fixture(scope, %{}, token: nil)
      assert Settings.clear_elorus_token(scope) == :ok
    end

    test "leaves the key of other users", %{scope: scope} do
      other = user_scope_fixture()
      settings_fixture(other)
      settings_fixture(scope)

      Settings.clear_elorus_token(scope)

      assert Settings.elorus_configured?(other)
      assert {:ok, _} = Settings.unseal_elorus_credentials(other, valid_user_password())
    end
  end

  describe "elorus_configured?/1" do
    test "needs the API key and the organization", %{scope: scope} do
      refute Settings.elorus_configured?(scope)

      settings_fixture(scope, %{elorus_organization_id: ""}, token: @token)
      refute Settings.elorus_configured?(scope)

      Settings.update_settings(scope, %{"elorus_organization_id" => "123"})
      assert Settings.elorus_configured?(scope)

      Settings.clear_elorus_token(scope)
      refute Settings.elorus_configured?(scope)

      settings_fixture(scope, %{elorus_organization_id: "123"}, token: nil)
      refute Settings.elorus_configured?(scope)
    end

    test "is about the user of the scope", %{scope: scope} do
      settings_fixture(user_scope_fixture())

      refute Settings.elorus_configured?(scope)
    end
  end

  describe "reseal_elorus_token/3" do
    test "seals the key again, for the new password", %{scope: scope} do
      settings_fixture(scope, %{}, token: @token)
      old = stored(scope)
      new_password = "another password 456"

      assert Settings.reseal_elorus_token(scope, valid_user_password(), new_password) == :ok

      row = stored(scope)
      assert row.elorus_token_sealed != old.elorus_token_sealed
      assert row.elorus_token_salt != old.elorus_token_salt

      assert SealedToken.unseal(
               row.elorus_token_sealed,
               row.elorus_token_salt,
               new_password,
               scope.user.id
             ) == {:ok, @token}

      assert SealedToken.unseal(
               row.elorus_token_sealed,
               row.elorus_token_salt,
               valid_user_password(),
               scope.user.id
             ) == {:error, :undecryptable}
    end

    test "leaves the key as it was when the old password does not open it", %{scope: scope} do
      settings_fixture(scope, %{}, token: @token)
      old = stored(scope)

      assert Settings.reseal_elorus_token(scope, "not the old password", "another password 456") ==
               {:error, :undecryptable}

      assert stored(scope).elorus_token_sealed == old.elorus_token_sealed
    end

    test "locks what was open", %{scope: scope} do
      settings_fixture(scope, %{}, token: @token)
      Connection.put_credentials(scope, elorus_credentials_fixture())

      Settings.reseal_elorus_token(scope, valid_user_password(), "another password 456")

      refute Connection.unlocked?(scope)
    end

    test "has nothing to do without a key", %{scope: scope} do
      assert Settings.reseal_elorus_token(scope, "old password 123", "new password 123") == :ok

      settings_fixture(scope, %{}, token: nil)
      assert Settings.reseal_elorus_token(scope, "old password 123", "new password 123") == :ok
    end
  end

  describe "the settings of a user" do
    test "are deleted with the user", %{scope: scope} do
      settings_fixture(scope)
      settings_fixture(user_scope_fixture())

      Repo.delete!(scope.user)

      assert Repo.aggregate(UserSettings, :count) == 1
      assert Repo.get_by(UserSettings, user_id: scope.user.id) == nil
    end

    test "are not those of another user, and the other cannot change them", %{scope: scope} do
      other = user_scope_fixture()
      settings_fixture(scope, %{business_name: "Mine"})

      assert {:ok, _} = Settings.update_settings(other, %{"business_name" => "Theirs"})
      assert Settings.clear_elorus_token(other) == :ok

      assert Settings.get_settings(scope).business_name == "Mine"
      assert Settings.elorus_configured?(scope)
    end
  end

  # What the sealed key opens to, with the password of the fixtures
  defp open(scope) do
    row = stored(scope)

    SealedToken.unseal(
      row.elorus_token_sealed,
      row.elorus_token_salt,
      valid_user_password(),
      scope.user.id
    )
  end
end
