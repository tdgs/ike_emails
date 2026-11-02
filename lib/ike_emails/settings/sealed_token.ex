defmodule IkeEmails.Settings.SealedToken do
  @moduledoc """
  Seals the Elorus API key of a user, to keep it in the database. It cannot be
  hashed, as the key itself is needed to call Elorus, so it is encrypted
  (XChaCha20-Poly1305, with `Plug.Crypto.MessageEncryptor`) under a key that
  needs two secrets:

      key = HMAC-SHA256(server key, PBKDF2-SHA256(password, salt, iterations))

  A dump of the database alone is useless, as it lacks the server key. With the
  server key too, the password of the user still has to be guessed, and each
  guess costs the iterations of PBKDF2.

  The sealed value is `"<id of the server key>.XCP.<ciphertext>"`. The user id
  is authenticated with it, so one that is copied to the row of another user
  does not decrypt.

  The server keys are read at every call from the configuration, the first of
  the list is the one that seals (see `config/runtime.exs`):

      config :ike_emails, #{inspect(__MODULE__)},
        keys: [{"2", <<32 bytes>>}, {"1", <<32 bytes>>}],
        iterations: 600_000

  A value sealed with an older key still opens, and `current_key?/1` tells that
  it should be sealed again, which is possible when the password is at hand.
  """

  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageEncryptor

  @key_bytes 32
  @salt_bytes 16
  @aad "ike_emails:elorus_api_token:v1:"

  @doc """
  The API key as it is sent to Elorus: spaces around it are trimmed, and what is
  left is 8 to 200 printable ASCII characters, with no space. Anything else
  (a line break in a pasted key, say) would end up in a header, and Mint echoes
  the value of an invalid header in its error.

  Returns `{:ok, token}` or `{:error, :invalid_token}`.
  """
  def normalize_token(token) when is_binary(token) do
    token = String.trim(token)

    if String.match?(token, ~r/\A[\x21-\x7E]{8,200}\z/),
      do: {:ok, token},
      else: {:error, :invalid_token}
  end

  def normalize_token(_token), do: {:error, :invalid_token}

  @doc """
  Seals the token of the user, under the key of the server and the password. A
  new salt is made at every call.

  Returns `{sealed, salt}`, which are kept together.
  """
  def seal(token, password, user_id) when is_binary(token) and is_binary(password) do
    {key_id, server_key} = keys!() |> List.first()

    salt = :crypto.strong_rand_bytes(@salt_bytes)
    key = derive_key(password, salt, server_key)
    ciphertext = MessageEncryptor.encrypt(token, aad(user_id), key, key)

    {key_id <> "." <> ciphertext, Base.url_encode64(salt, padding: false)}
  end

  @doc """
  Opens what `seal/3` made. A wrong password, a value that was changed, one that
  was sealed for another user and one whose server key is gone are all
  `{:error, :undecryptable}`.
  """
  def unseal(sealed, salt, password, user_id)
      when is_binary(sealed) and is_binary(salt) and is_binary(password) do
    with [key_id, "XCP." <> _ = ciphertext] <- String.split(sealed, ".", parts: 2),
         {_id, server_key} <- List.keyfind(keys!(), key_id, 0),
         {:ok, salt} <- Base.url_decode64(salt, padding: false),
         key = derive_key(password, salt, server_key),
         {:ok, token} <- MessageEncryptor.decrypt(ciphertext, aad(user_id), key, key) do
      {:ok, token}
    else
      _ -> {:error, :undecryptable}
    end
  end

  def unseal(_sealed, _salt, _password, _user_id), do: {:error, :undecryptable}

  @doc """
  Whether the value was sealed with the key that seals now. When it was not, it
  should be sealed again, once it is open.
  """
  def current_key?(sealed) when is_binary(sealed) do
    {key_id, _key} = List.first(keys!())
    String.starts_with?(sealed, key_id <> ".")
  end

  defp derive_key(password, salt, server_key) do
    password
    |> KeyGenerator.generate(salt, iterations: iterations(), length: @key_bytes, digest: :sha256)
    |> then(&:crypto.mac(:hmac, :sha256, server_key, &1))
  end

  defp aad(user_id), do: @aad <> to_string(user_id)

  defp iterations, do: Keyword.fetch!(config(), :iterations)

  defp keys! do
    case Keyword.get(config(), :keys) do
      [_ | _] = keys ->
        Enum.each(keys, &check_key!/1)
        keys

      _ ->
        raise ArgumentError,
              "no server key to seal the API keys with, see SETTINGS_ENCRYPTION_KEY in config/runtime.exs"
    end
  end

  # What is wrong is told without the key
  defp check_key!({id, key})
       when is_binary(id) and id != "" and is_binary(key) and byte_size(key) == @key_bytes do
    if String.contains?(id, "."), do: raise(ArgumentError, "the id of a server key has a dot")
  end

  defp check_key!(_key) do
    raise ArgumentError,
          "a server key to seal the API keys with must be {id, key}, a key of #{@key_bytes} bytes"
  end

  defp config, do: Application.fetch_env!(:ike_emails, __MODULE__)
end
