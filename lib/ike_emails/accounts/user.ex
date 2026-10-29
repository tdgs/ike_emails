defmodule IkeEmails.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  # bcrypt only reads the first 72 bytes of a password
  @max_password_bytes 72

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset of a new user: the email, and the password that is stored hashed.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_email()
    |> validate_password()
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, IkeEmails.Repo)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12)
    |> validate_length(:password, max: @max_password_bytes, count: :bytes)
    |> hash_password()
  end

  # The password is only hashed when it is valid, and is not kept
  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Whether the password is the one of the user. Without a user the time is spent
  all the same, so that the answer does not tell which emails are known.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and is_binary(password) do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_user, _password) do
    Bcrypt.no_user_verify()
    false
  end
end
