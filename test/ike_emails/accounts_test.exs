defmodule IkeEmails.AccountsTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Accounts
  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Accounts.User

  @password "a long enough password"

  describe "register_user/1" do
    test "stores a user with a hashed password" do
      assert {:ok, user} = Accounts.register_user(%{email: "me@example.com", password: @password})

      assert user.email == "me@example.com"
      assert user.password == nil
      assert "$2" <> _ = user.hashed_password
      refute user.hashed_password =~ @password
      assert %User{id: id} = Repo.get_by!(User, email: "me@example.com")
      assert id == user.id
    end

    test "trims and downcases the email" do
      assert {:ok, user} =
               Accounts.register_user(%{email: "  Me@Example.COM ", password: @password})

      assert user.email == "me@example.com"
    end

    test "works with string keys, as the params of a request" do
      assert {:ok, %{email: "me@example.com"}} =
               Accounts.register_user(%{"email" => "me@example.com", "password" => @password})
    end

    test "requires an email and a password" do
      assert {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
      assert Repo.aggregate(User, :count) == 0
    end

    test "requires a blank-free email with an @ sign" do
      for email <- ["no-at-sign", "with space@example.com", "two@@example.com", "@example.com"] do
        assert {:error, changeset} = Accounts.register_user(%{email: email, password: @password})
        assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
      end
    end

    test "limits the length of the email" do
      email = String.duplicate("a", 150) <> "@example.com"

      assert {:error, changeset} = Accounts.register_user(%{email: email, password: @password})
      assert %{email: ["should be at most 160 character(s)"]} = errors_on(changeset)
    end

    test "requires a password of at least 12 characters" do
      assert {:error, changeset} =
               Accounts.register_user(%{email: "me@example.com", password: "short"})

      assert %{password: ["should be at least 12 character(s)"]} = errors_on(changeset)

      assert {:ok, _user} =
               Accounts.register_user(%{email: "me@example.com", password: "exactly12chr"})
    end

    test "limits the password to the 72 bytes bcrypt reads" do
      assert {:ok, _user} =
               Accounts.register_user(%{
                 email: "a@example.com",
                 password: String.duplicate("a", 72)
               })

      assert {:error, changeset} =
               Accounts.register_user(%{
                 email: "b@example.com",
                 password: String.duplicate("a", 73)
               })

      assert %{password: ["should be at most 72 byte(s)"]} = errors_on(changeset)

      # 37 characters, 74 bytes
      assert {:error, changeset} =
               Accounts.register_user(%{
                 email: "c@example.com",
                 password: String.duplicate("é", 37)
               })

      assert %{password: ["should be at most 72 byte(s)"]} = errors_on(changeset)
    end

    test "does not hash an invalid password" do
      changeset =
        User.registration_changeset(%User{}, %{email: "nope", password: "a long enough password"})

      refute changeset.valid?
      refute Map.has_key?(changeset.changes, :hashed_password)
    end

    test "refuses an email that is taken, whatever its case" do
      user_fixture(%{email: "me@example.com"})

      assert {:error, changeset} =
               Accounts.register_user(%{email: "me@example.com", password: @password})

      assert %{email: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               Accounts.register_user(%{email: "ME@Example.com", password: @password})

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "the database refuses an email that is taken too" do
      user = user_fixture()

      changeset =
        %User{}
        |> User.registration_changeset(%{email: "fresh@example.com", password: @password})
        # Skips the check of the changeset, as a race between two requests would
        |> Ecto.Changeset.put_change(:email, user.email)

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "get_user_by_email_and_password/2" do
    setup do
      %{user: user_fixture(%{email: "me@example.com", password: @password})}
    end

    test "returns the user for the right password", %{user: user} do
      assert %User{id: id} = Accounts.get_user_by_email_and_password("me@example.com", @password)
      assert id == user.id
    end

    test "does not care about the case of the email or the spaces around it", %{user: user} do
      assert %User{id: id} =
               Accounts.get_user_by_email_and_password("  ME@example.com ", @password)

      assert id == user.id
    end

    test "is nil for a wrong password" do
      assert Accounts.get_user_by_email_and_password("me@example.com", "not the password") == nil
      assert Accounts.get_user_by_email_and_password("me@example.com", @password <> " ") == nil
      assert Accounts.get_user_by_email_and_password("me@example.com", "") == nil
    end

    test "the password is case sensitive" do
      assert Accounts.get_user_by_email_and_password("me@example.com", String.upcase(@password)) ==
               nil
    end

    test "is nil for an unknown email" do
      assert Accounts.get_user_by_email_and_password("you@example.com", @password) == nil
    end

    test "is nil for what is not text" do
      assert Accounts.get_user_by_email_and_password(nil, @password) == nil
      assert Accounts.get_user_by_email_and_password("me@example.com", nil) == nil
      assert Accounts.get_user_by_email_and_password(%{}, [@password]) == nil
      assert Accounts.get_user_by_email_and_password(123, 456) == nil
    end

    test "tells the passwords of two users apart" do
      other = user_fixture(%{email: "other@example.com", password: "the other password"})

      assert Accounts.get_user_by_email_and_password("me@example.com", "the other password") ==
               nil

      assert %User{id: id} =
               Accounts.get_user_by_email_and_password("other@example.com", "the other password")

      assert id == other.id
    end
  end

  describe "get_user/1 and get_user!/1" do
    test "get the user by id" do
      user = user_fixture()

      assert %User{id: id} = Accounts.get_user(user.id)
      assert id == user.id
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end

    test "get_user/1 is nil and get_user!/1 raises for an unknown id" do
      assert Accounts.get_user(-1) == nil
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(-1) end
    end
  end

  describe "error_messages/1" do
    test "lists what is wrong, with the limits filled in" do
      assert {:error, changeset} =
               Accounts.register_user(%{email: "nope", password: "short"})

      assert Accounts.error_messages(changeset) == %{
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"]
             }
    end
  end

  describe "valid_password?/2" do
    test "is false without a user, or without a password to compare" do
      refute User.valid_password?(nil, @password)
      refute User.valid_password?(%User{hashed_password: nil}, @password)
      refute User.valid_password?(%User{hashed_password: "x"}, nil)
    end
  end

  describe "Scope" do
    test "for_user/1 wraps the user, and nothing is no scope" do
      user = user_fixture()

      assert %Scope{user: ^user} = scope = Scope.for_user(user)
      assert Scope.user_id(scope) == user.id
      assert Scope.for_user(nil) == nil
    end

    test "authorize!/2 returns the records of the user and raises for others" do
      user = user_fixture()
      scope = Scope.for_user(user)

      mine = %IkeEmails.Banking.Transaction{user_id: user.id}
      theirs = %IkeEmails.Banking.Transaction{user_id: user.id + 1}

      assert Scope.authorize!(scope, mine) == mine
      assert_raise ArgumentError, fn -> Scope.authorize!(scope, theirs) end
    end
  end
end
