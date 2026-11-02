defmodule IkeEmails.Elorus.Locks do
  @moduledoc """
  How many times the credentials of each user were locked: the epoch of the user.

  Opening the API key takes a while (`IkeEmails.Elorus.Connection.unlock/2`), and
  a lock that comes meanwhile finds no process to end, so it would leave no trace,
  and the key would be handed over after it. The unlock reads the epoch before it
  opens the key, and the process of the connection takes the credentials only if
  the epoch is still the same.

  This process only owns the table, and is started before the connections.
  """

  use GenServer

  @table __MODULE__

  @doc """
  The number of times the credentials of the user were locked since the server
  started.
  """
  def epoch(user_id), do: :ets.lookup_element(@table, user_id, 2, 0)

  @doc """
  Counts a lock of the credentials of the user, which refuses the unlocks that
  read the epoch before.
  """
  def bump(user_id) do
    _ = :ets.update_counter(@table, user_id, 1, {user_id, 0})
    :ok
  end

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    _ = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
