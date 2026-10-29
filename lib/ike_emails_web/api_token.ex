defmodule IkeEmailsWeb.ApiToken do
  @moduledoc """
  The token the bank crawler pushes transactions with. It is signed with the
  `secret_key_base`, carries the id of the user and expires, so nothing is kept
  of it: the crawler gets one for the email and password of the user, see
  `IkeEmailsWeb.ApiTokenController`, and asks for another when it expires.
  """

  @salt "bank api token"
  @max_age 86_400

  @doc """
  How long a token is good for, in seconds.
  """
  def max_age, do: @max_age

  @doc """
  A token for the user. `opts` are those of `Phoenix.Token.sign/4`.
  """
  def generate(%IkeEmails.Accounts.User{id: id}, opts \\ []) do
    Phoenix.Token.sign(IkeEmailsWeb.Endpoint, @salt, id, opts)
  end

  @doc """
  The id of the user the token is for: `{:ok, user_id}`, or `{:error, reason}`
  when it is forged, malformed or expired.
  """
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(IkeEmailsWeb.Endpoint, @salt, token, max_age: @max_age)
  end

  def verify(_token), do: {:error, :invalid}
end
