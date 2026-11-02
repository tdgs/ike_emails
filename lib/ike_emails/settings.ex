defmodule IkeEmails.Settings do
  @moduledoc """
  The settings of a user: who they are as the issuer of the invoices imported from
  Elorus, and the Elorus account to read them from.

  The API key of Elorus is kept sealed, with the server key and the login password
  of the user (see `IkeEmails.Settings.SealedToken`), so the password is needed to
  save it and to use it. It is opened in `IkeEmails.Elorus.Connection`, which holds
  it for a while. A change of the password has to seal it again
  (`reseal_elorus_token/3`) and a reset has to remove it (`clear_elorus_token/1`),
  see `IkeEmails.Accounts`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Accounts.User
  alias IkeEmails.Elorus.Connection
  alias IkeEmails.Elorus.Credentials
  alias IkeEmails.Repo
  alias IkeEmails.Settings.SealedToken
  alias IkeEmails.Settings.UserSettings

  @doc """
  The settings of the user, or empty ones that are not saved yet: never `nil`.

  The sealed API key is not read. `:elorus_token_set` tells whether there is one.
  """
  def get_settings(%Scope{} = scope) do
    user_id = Scope.user_id(scope)
    fields = UserSettings.__schema__(:fields) -- [:elorus_token_sealed]

    Repo.one(
      from s in UserSettings,
        where: s.user_id == ^user_id,
        select: struct(s, ^fields),
        select_merge: %{elorus_token_set: not is_nil(s.elorus_token_sealed)}
    ) || %UserSettings{user_id: user_id}
  end

  @doc """
  Changeset of the settings of the user, for the form.
  """
  def change_settings(%Scope{} = scope, attrs \\ %{}) do
    scope |> get_settings() |> UserSettings.changeset(attrs)
  end

  @doc """
  Saves the business and the Elorus organization of the user. A change of the
  organization or of the demo flag locks the API key again, which is for the
  organization it was opened for.
  """
  def update_settings(%Scope{} = scope, attrs) do
    settings = get_settings(scope)

    with {:ok, saved} <- settings |> UserSettings.changeset(attrs) |> Repo.insert_or_update() do
      if saved.elorus_organization_id != settings.elorus_organization_id or
           saved.elorus_demo != settings.elorus_demo do
        Connection.lock(scope)
      end

      {:ok, saved}
    end
  end

  @doc """
  Seals the API key of Elorus with the password of the user and stores it, in
  place of the one there was. The password is checked first.

  Returns `{:ok, settings}`, `{:error, :invalid_password}`,
  `{:error, :invalid_token}` (see `IkeEmails.Settings.SealedToken.normalize_token/1`)
  or `{:error, changeset}`.
  """
  def set_elorus_token(%Scope{} = scope, token, password) do
    with :ok <- check_password(scope, password),
         {:ok, token} <- SealedToken.normalize_token(token) do
      user_id = Scope.user_id(scope)
      {sealed, salt} = SealedToken.seal(token, password, user_id)

      case scope
           |> get_settings()
           |> UserSettings.token_changeset(sealed, salt)
           |> Repo.insert_or_update() do
        {:ok, saved} ->
          Logger.info("User #{user_id} set the Elorus API key")
          Connection.lock(scope)

          # What is returned does not hold the sealed key
          {:ok, %{saved | elorus_token_sealed: nil, elorus_token_set: true}}

        {:error, _changeset} = error ->
          error
      end
    end
  end

  @doc """
  Opens the API key of Elorus of the user with their password.

  Returns `{:ok, credentials}`, or `{:error, reason}`: `:not_configured` (there is
  no API key or no organization), `:invalid_password`, or `:undecryptable` (the
  password is the one of the user, but the key does not open: it was sealed with
  a server key that is gone, for example, and has to be set again).
  """
  def unseal_elorus_credentials(%Scope{} = scope, password) do
    with %UserSettings{} = settings <- configured_settings(scope),
         :ok <- check_password(scope, password),
         {:ok, token} <-
           SealedToken.unseal(
             settings.elorus_token_sealed,
             settings.elorus_token_salt,
             password,
             settings.user_id
           ) do
      reseal_if_old(settings, token, password)

      {:ok,
       %Credentials{
         api_token: token,
         organization_id: settings.elorus_organization_id,
         demo: settings.elorus_demo
       }}
    else
      nil -> {:error, :not_configured}
      {:error, _reason} = error -> error
    end
  end

  # The only place that reads the sealed key
  defp configured_settings(scope) do
    Repo.one(configured_query(scope))
  end

  defp configured_query(scope) do
    from s in UserSettings,
      where:
        s.user_id == ^Scope.user_id(scope) and not is_nil(s.elorus_token_sealed) and
          not is_nil(s.elorus_token_salt) and not is_nil(s.elorus_organization_id)
  end

  # Sealed with a server key that is not the current one: the password is at hand,
  # so it is sealed again with the current one. It is only stored if the key was
  # not changed meanwhile, and failing to is no reason to refuse the unlock.
  defp reseal_if_old(settings, token, password) do
    unless SealedToken.current_key?(settings.elorus_token_sealed) do
      {sealed, salt} = SealedToken.seal(token, password, settings.user_id)

      {count, _} =
        Repo.update_all(
          from(s in UserSettings,
            where: s.id == ^settings.id and s.elorus_token_sealed == ^settings.elorus_token_sealed
          ),
          set: [elorus_token_sealed: sealed, elorus_token_salt: salt]
        )

      if count == 1,
        do: Logger.info("User #{settings.user_id} had the Elorus API key sealed again")
    end

    :ok
  end

  @doc """
  Seals the API key again, for a new password: the key is opened with the old one.
  A change of the password has to call this. There is nothing to do without a key.

  Returns `:ok`, or `{:error, :undecryptable}` when the old password does not open
  it.
  """
  def reseal_elorus_token(%Scope{} = scope, old_password, new_password)
      when is_binary(old_password) and is_binary(new_password) do
    case Repo.one(from s in UserSettings, where: s.user_id == ^Scope.user_id(scope)) do
      %UserSettings{elorus_token_sealed: sealed} = settings when is_binary(sealed) ->
        with {:ok, token} <-
               SealedToken.unseal(
                 sealed,
                 settings.elorus_token_salt,
                 old_password,
                 settings.user_id
               ) do
          {sealed, salt} = SealedToken.seal(token, new_password, settings.user_id)

          settings |> UserSettings.token_changeset(sealed, salt) |> Repo.update!()
          Logger.info("User #{settings.user_id} had the Elorus API key sealed for a new password")
          Connection.lock(scope)
          :ok
        end

      _none ->
        :ok
    end
  end

  @doc """
  Removes the API key of Elorus of the user, which needs no password. A key that
  is open is forgotten.
  """
  def clear_elorus_token(%Scope{} = scope) do
    user_id = Scope.user_id(scope)

    {count, _} =
      Repo.update_all(
        from(s in UserSettings,
          where: s.user_id == ^user_id and not is_nil(s.elorus_token_sealed)
        ),
        set: [elorus_token_sealed: nil, elorus_token_salt: nil]
      )

    if count > 0, do: Logger.info("User #{user_id} removed the Elorus API key")
    Connection.lock(scope)
    :ok
  end

  @doc """
  Whether the user has an API key and an organization for Elorus. Nothing is
  opened for this, so it does not tell whether the key is unlocked, see
  `IkeEmails.Elorus.Connection.unlocked?/1`.
  """
  def elorus_configured?(%Scope{} = scope) do
    scope |> configured_query() |> Repo.exists?()
  end

  @doc """
  Who the user is as the issuer of the invoices imported from Elorus, as
  `%{name: name, vat: vat}` (the VAT number may be `nil`), or `nil` without a name.
  """
  def business(%Scope{} = scope) do
    settings = get_settings(scope)

    case present(settings.business_name) do
      nil -> nil
      name -> %{name: name, vat: present(settings.business_vat)}
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp check_password(%Scope{user: %User{} = user}, password) when is_binary(password) do
    if User.valid_password?(user, password), do: :ok, else: {:error, :invalid_password}
  end

  defp check_password(_scope, _password), do: {:error, :invalid_password}
end
