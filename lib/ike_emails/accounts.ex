defmodule IkeEmails.Accounts do
  @moduledoc """
  The users. There is no sign-up: they are created with `mix user.create`, or
  `IkeEmails.Release.create_user/2` in production.
  """

  alias IkeEmails.Accounts.User
  alias IkeEmails.Repo

  @doc """
  Creates a user from an `email` and a `password` (at least 12 characters).
  """
  def register_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  def get_user(id), do: Repo.get(User, id)

  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  The user with that email and password, or `nil`.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email |> String.trim() |> String.downcase())
    if User.valid_password?(user, password), do: user
  end

  def get_user_by_email_and_password(_email, _password), do: nil

  @doc """
  What is wrong with a changeset, as `%{field => [message]}`.
  """
  def error_messages(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
