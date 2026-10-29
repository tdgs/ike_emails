defmodule IkeEmails.Accounts.Scope do
  @moduledoc """
  Who a call is made for. Every function that reads or writes the data of a user
  takes the scope as its first argument, and only sees that user's rows.
  """

  alias IkeEmails.Accounts.User

  defstruct user: nil

  @doc """
  The scope of a user, or `nil` when there is none.
  """
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc """
  The id of the user of the scope.
  """
  def user_id(%__MODULE__{user: %User{id: id}}), do: id

  @doc """
  Returns the record when it belongs to the user of the scope, and raises when it
  does not. The records come from queries of the scope, so this is a second line
  of defence for the functions that are given one.
  """
  def authorize!(%__MODULE__{} = scope, %{user_id: user_id} = record) do
    if user_id == user_id(scope) do
      record
    else
      raise ArgumentError, "the #{inspect(record.__struct__)} belongs to another user"
    end
  end
end
