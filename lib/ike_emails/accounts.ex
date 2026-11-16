defmodule IkeEmails.Accounts do
  @moduledoc """
  The users. There is no sign-up: they are created with `mix user.create`, or
  `IkeEmails.Release.create_user/1` in production.
  """

  alias IkeEmails.Accounts.LoginThrottle
  alias IkeEmails.Accounts.User
  alias IkeEmails.Repo

  # The Elorus API key of a user is sealed with their password (see
  # IkeEmails.Settings), and there is no way to change a password yet. When there is,
  # a change must call IkeEmails.Settings.reseal_elorus_token(scope, old, new), and a
  # reset (the old password is not known) must call
  # IkeEmails.Settings.clear_elorus_token(scope), or the key cannot be opened any more.

  @doc """
  Creates a user from an `email` and a `password` (at least 12 characters).
  """
  def register_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  def get_user(id), do: Repo.get(User, id)

  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  The user with that email and password, or `nil`. It is `nil` also while the user is
  locked out for too many wrong passwords, see `IkeEmails.Accounts.LoginThrottle`.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email |> String.trim() |> String.downcase())

    cond do
      # The time of a check is spent all the same, so that the answer does not tell
      # that the email is a user's
      user && LoginThrottle.attempt(user.id) == :locked ->
        User.valid_password?(nil, password)
        nil

      User.valid_password?(user, password) ->
        LoginThrottle.succeeded(user.id)
        user

      true ->
        nil
    end
  end

  def get_user_by_email_and_password(_email, _password), do: nil
end
