defmodule IkeEmails.Settings.SealedTokenTest do
  # Not async: some tests change the keys of the server
  use IkeEmails.DataCase, async: false

  import IkeEmails.Fixtures

  alias IkeEmails.Settings.SealedToken

  @token "an-elorus-api-key-1234"
  @password "a valid password 123"

  setup do
    original = Application.fetch_env!(:ike_emails, SealedToken)
    on_exit(fn -> Application.put_env(:ike_emails, SealedToken, original) end)
    %{original: original}
  end

  defp put_config(changes) do
    config = Application.fetch_env!(:ike_emails, SealedToken)
    Application.put_env(:ike_emails, SealedToken, Keyword.merge(config, changes))
  end

  defp key(byte), do: :binary.copy(<<byte>>, 32)

  describe "seal/3 and unseal/4" do
    test "return the token" do
      {sealed, salt} = SealedToken.seal(@token, @password, 1)

      assert SealedToken.unseal(sealed, salt, @password, 1) == {:ok, @token}
    end

    test "keep the id of the server key in front, and no token in the value" do
      {sealed, _salt} = SealedToken.seal(@token, @password, 1)

      assert String.starts_with?(sealed, "1.XCP.")
      refute sealed =~ @token
    end

    test "make a new salt every time" do
      {sealed_a, salt_a} = SealedToken.seal(@token, @password, 1)
      {sealed_b, salt_b} = SealedToken.seal(@token, @password, 1)

      assert salt_a != salt_b
      assert sealed_a != sealed_b
      assert {:ok, bytes} = Base.url_decode64(salt_a, padding: false)
      assert byte_size(bytes) == 16
    end

    test "do not open with another password" do
      {sealed, salt} = SealedToken.seal(@token, @password, 1)

      assert SealedToken.unseal(sealed, salt, "another password 456", 1) ==
               {:error, :undecryptable}

      assert SealedToken.unseal(sealed, salt, "", 1) == {:error, :undecryptable}
    end

    test "do not open when the salt is another" do
      {sealed, _salt} = SealedToken.seal(@token, @password, 1)
      {_sealed, other_salt} = SealedToken.seal(@token, @password, 1)

      assert SealedToken.unseal(sealed, other_salt, @password, 1) == {:error, :undecryptable}
      assert SealedToken.unseal(sealed, "not a salt!", @password, 1) == {:error, :undecryptable}
    end

    test "do not open what was changed" do
      {sealed, salt} = SealedToken.seal(@token, @password, 1)
      # A character of the middle: the last one of a base64 value can have bits
      # that mean nothing, and a change in them is the same bytes
      {head, <<char, tail::binary>>} = String.split_at(sealed, 20)
      tampered = head <> <<if(char == ?A, do: ?B, else: ?A)>> <> tail

      for bad <- [tampered, "1.XCP.", "1.", "1", "", "XCP.abc", "2.XCP.abc", "1.garbage"] do
        assert SealedToken.unseal(bad, salt, @password, 1) == {:error, :undecryptable}
      end
    end

    test "do not open for another user" do
      {sealed, salt} = SealedToken.seal(@token, @password, 1)

      assert SealedToken.unseal(sealed, salt, @password, 2) == {:error, :undecryptable}
      assert SealedToken.unseal(sealed, salt, @password, 1) == {:ok, @token}
    end

    test "do not open what is not a string" do
      assert SealedToken.unseal(nil, nil, @password, 1) == {:error, :undecryptable}
      assert SealedToken.unseal("1.XCP.abc", nil, @password, 1) == {:error, :undecryptable}
    end

    test "need the server key too" do
      {sealed, salt} = SealedToken.seal(@token, @password, 1)

      put_config(keys: [{"1", key(7)}])

      assert SealedToken.unseal(sealed, salt, @password, 1) == {:error, :undecryptable}
    end
  end

  describe "the server keys" do
    test "do not open what a key that is gone sealed" do
      {sealed, salt} = SealedToken.seal(@token, @password, 1)

      put_config(keys: [{"2", key(2)}])

      assert SealedToken.unseal(sealed, salt, @password, 1) == {:error, :undecryptable}
    end

    test "must be 32 bytes, and the error does not show them" do
      for bad <- ["supersecretkey-too-short-abcde", "supersecretkey-too-long-abcdefghi", ""] do
        put_config(keys: [{"1", bad}])

        error = assert_raise ArgumentError, fn -> SealedToken.seal(@token, @password, 1) end
        refute error.message =~ "supersecret"

        assert_raise ArgumentError, fn ->
          SealedToken.unseal("1.XCP.abc", "AAAA", @password, 1)
        end
      end
    end

    test "must have an id that has no dot, and there must be one" do
      put_config(keys: [{"a.b", key(1)}])
      assert_raise ArgumentError, fn -> SealedToken.seal(@token, @password, 1) end

      put_config(keys: [{"", key(1)}])
      assert_raise ArgumentError, fn -> SealedToken.seal(@token, @password, 1) end

      put_config(keys: [])
      assert_raise ArgumentError, fn -> SealedToken.seal(@token, @password, 1) end
    end
  end

  describe "normalize_token/1" do
    test "takes a token that is printable ASCII, and trims it" do
      assert SealedToken.normalize_token("  abcdefgh1234\n") == {:ok, "abcdefgh1234"}
      assert SealedToken.normalize_token("Zk9-_.~!#abc") == {:ok, "Zk9-_.~!#abc"}
      assert {:ok, _} = SealedToken.normalize_token(String.duplicate("a", 200))
    end

    test "refuses what would not be a header value, or is not a token" do
      for bad <- [
            "short",
            String.duplicate("a", 201),
            "has a space 12345",
            "line\nbreak12345",
            "tab\tbreak12345",
            "null\0byte12345",
            "carriage\rreturn12345",
            "accént-12345678",
            "日本語日本語日本語日本語",
            "",
            "   ",
            nil,
            12_345_678
          ] do
        assert SealedToken.normalize_token(bad) == {:error, :invalid_token}
      end
    end
  end

  describe "in the database" do
    setup :create_user_scope

    test "the column holds the sealed value, and neither the token nor the password", %{
      scope: scope
    } do
      settings_fixture(scope, %{}, token: @token)

      %{rows: [[sealed, salt]]} =
        Repo.query!("SELECT elorus_token_sealed, elorus_token_salt FROM user_settings")

      assert String.starts_with?(sealed, "1.XCP.")
      refute sealed =~ @token
      refute salt =~ @token
      refute sealed =~ valid_user_password()
      refute salt =~ valid_user_password()
    end
  end
end
