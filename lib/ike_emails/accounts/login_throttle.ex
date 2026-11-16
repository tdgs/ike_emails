defmodule IkeEmails.Accounts.LoginThrottle do
  @moduledoc """
  Stops the guessing of a password. Every login of a user is counted before its
  password is checked, so that guesses sent at the same time are counted too. After 10
  within 15 minutes of the first, every login of that user is refused until those 15
  minutes are over, with the right password too. A login that works clears the count.

  Only users that exist are counted, so emails that are made up cannot fill the table.
  The counts are in memory, on the one node, and a restart forgets them: enough for one
  server. Anyone who knows the email can keep its user locked out this way; the answer
  stays "Invalid email or password." so that it does not tell which emails exist.
  """

  use GenServer

  @table __MODULE__
  @max_failures 10
  @window :timer.minutes(15)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Counts a login of the user that is about to be checked, and says whether it may be:
  `:ok`, or `:locked` once there were 10 in the window. The count starts again once 15
  minutes have passed since the first.
  """
  def attempt(user_id) do
    now = now()

    # A window that is over starts again, in one step, so that two logins at once
    # cannot both start it and lose one of the counts
    :ets.select_replace(@table, [
      {{user_id, :_, :"$1"}, [{:>=, {:-, now, :"$1"}, @window}], [{{user_id, 0, now}}]}
    ])

    count = :ets.update_counter(@table, user_id, {2, 1}, {user_id, 0, now})
    if count > @max_failures, do: :locked, else: :ok
  end

  @doc "Clears the count after a login that worked."
  def succeeded(user_id) do
    :ets.delete(@table, user_id)
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
