defmodule IkeEmails.Elorus.Connection do
  @moduledoc """
  The Elorus credentials of a user who unlocked them, in a process of their own:
  one per user, which makes the calls to Elorus for them.

  The API key is kept sealed with the password of the user (see
  `IkeEmails.Settings`), so it is opened when the user gives the password
  (`unlock/2`), and is kept here, and nowhere else, until the process has not been
  used for a while (`idle_timeout` in the configuration, 15 minutes), or the user
  locks it (`lock/1`), logs out, or changes the Elorus settings. A restart of the
  server locks everyone. The credentials are not in the database, the session,
  the assigns of a LiveView or a flash.

  The requests are made inside the process, so the API key does not leave it,
  and a user makes one at a time, which suits the limits of Elorus (60 a minute
  and 1000 a day for a user). Every call extends the window. Without a process the
  calls return `{:error, :locked}`, and so they do when it ends while one is made.

  It is started on demand under a `DynamicSupervisor`, never restarted: a crash
  means locked, not a process with stale or no credentials. It starts with the id
  of the user only, and the credentials arrive in a call, so that the supervisor
  does not keep them.

  What is done so that the API key is not seen:

    * The credentials are in a private ETS table of the process, not in its state
      or its dictionary: `:sys.get_state/1` and `:sys.get_status/1` show the state
      and the whole dictionary of a process, and only the process can read its
      private table.
    * `Process.flag(:sensitive, true)` stops the tracing of the process, hides its
      messages and its dictionary from `Process.info/2`, and leaves them out of
      a crash dump.
    * `format_status/1` leaves the message that holds the credentials out of what
      a crash logs.
    * `IkeEmails.Elorus.Credentials` does not show the API key when inspected.

  Whoever can run code in the node can still read it from the memory of the
  process, for example by turning on `:sys.log/2` before an unlock. That is out of
  reach of what this guards against.

  A lock wins against an unlock that is in the middle of opening the key, see
  `IkeEmails.Elorus.Locks`.
  """

  use GenServer, restart: :temporary

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Elorus
  alias IkeEmails.Elorus.Credentials
  alias IkeEmails.Elorus.Locks
  alias IkeEmails.Settings

  @supervisor IkeEmails.Elorus.ConnectionSupervisor
  @registry IkeEmails.Elorus.Registry

  # Above what a request takes with its retries: 15 seconds a try, 3 tries and
  # the delays between them
  @call_timeout :timer.seconds(90)

  ## Client

  @doc """
  Opens the API key of the user with their password, and keeps it for the window.

  Returns `:ok`, or `{:error, reason}` as `IkeEmails.Settings.unseal_elorus_credentials/2`
  does: `:invalid_password`, `:undecryptable` or `:not_configured`. Opening it takes
  a while, as it is made to. When it is locked meanwhile (the user removed the key,
  changed the organization or logged out), the key is not kept: `{:error, :locked}`.
  """
  def unlock(%Scope{} = scope, password) do
    # Read before the key is opened: a lock after it refuses the credentials
    epoch = Locks.epoch(Scope.user_id(scope))

    with {:ok, %Credentials{} = credentials} <-
           Settings.unseal_elorus_credentials(scope, password) do
      put_credentials(scope, credentials, epoch)
    end
  end

  @doc false
  # Used by the tests, which have no sealed key to open
  def put_credentials(%Scope{} = scope, %Credentials{} = credentials) do
    put_credentials(scope, credentials, Locks.epoch(Scope.user_id(scope)))
  end

  @doc false
  # Used by `unlock/2`. `epoch` is the one that was read before the credentials were
  def put_credentials(%Scope{} = scope, %Credentials{} = credentials, epoch) do
    user_id = Scope.user_id(scope)

    # Locked already: there is no need to start a process for it
    if Locks.epoch(user_id) == epoch,
      do: hand_over(user_id, credentials, epoch, 1),
      else: {:error, :locked}
  end

  defp hand_over(user_id, credentials, epoch, retries) do
    with {:ok, pid} <- ensure_started(user_id) do
      GenServer.call(pid, {:put_credentials, credentials, epoch}, @call_timeout)
    end
  catch
    # It was locked while the call waited for it (the supervisor ends it with
    # `:shutdown`), and that is not undone by starting another one
    :exit, {:shutdown, {GenServer, :call, _args}} ->
      {:error, :locked}

    # It ended between finding it and the call, when it was not used for the window:
    # another one is started
    :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal] ->
      if retries > 0,
        do: hand_over(user_id, credentials, epoch, retries - 1),
        else: {:error, :locked}
  end

  @doc """
  Forgets the credentials of the user, at once, even when a request is made. There
  is nothing to do when they are locked already.
  """
  def lock(%Scope{} = scope) do
    user_id = Scope.user_id(scope)

    # Counted first, so that credentials that are on their way are refused when they
    # arrive, whether or not there is a process now to end
    Locks.bump(user_id)

    case whereis(user_id) do
      nil ->
        :ok

      pid ->
        # The supervisor ends it with `:shutdown`, which is not reported as a crash
        _ = DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok
    end
  end

  @doc """
  Whether the credentials of the user are unlocked. This does not extend the window.
  """
  def unlocked?(%Scope{} = scope), do: whereis(Scope.user_id(scope)) != nil

  @doc """
  `IkeEmails.Elorus.list_all_invoices/3` with the credentials of the user, or
  `{:error, :locked}`.
  """
  def list_all_invoices(%Scope{} = scope, params \\ [], opts \\ []) do
    call(scope, {:list_all_invoices, params, opts})
  end

  @doc """
  `IkeEmails.Elorus.invoice_pdf/2` with the credentials of the user, or
  `{:error, :locked}`.
  """
  def invoice_pdf(%Scope{} = scope, id) when is_binary(id) do
    call(scope, {:invoice_pdf, id})
  end

  defp call(scope, request) do
    case whereis(Scope.user_id(scope)) do
      nil ->
        {:error, :locked}

      pid ->
        # The spans of the requests are inside the one of the caller
        GenServer.call(pid, {:request, OpenTelemetry.Ctx.get_current(), request}, @call_timeout)
    end
  catch
    # The request is not over, and its answer is of no use any more
    :exit, {:timeout, {GenServer, :call, _args}} ->
      {:error, %Req.TransportError{reason: :timeout}}

    # It was locked or timed out while the call was made, or it crashed (which is
    # reported by the process, and leaves it locked)
    :exit, _reason ->
      {:error, :locked}
  end

  defp ensure_started(user_id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, user_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  # The registry forgets a process that ended a moment later, so it is not taken
  # for one that is there
  defp whereis(user_id) do
    case Registry.lookup(@registry, user_id) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp via(user_id), do: {:via, Registry, {@registry, user_id}}

  ## Server

  @doc false
  def start_link(user_id), do: GenServer.start_link(__MODULE__, user_id, name: via(user_id))

  @impl true
  def init(user_id) do
    Process.flag(:sensitive, true)

    # The credentials arrive in the next call. Without them it is not kept either
    {:ok, %{user_id: user_id, credentials: :ets.new(:credentials, [:private])}, idle_timeout()}
  end

  @impl true
  def handle_call({:put_credentials, %Credentials{} = credentials, epoch}, _from, state) do
    # Checked here, so that a lock is either before this, and refuses the credentials,
    # or after it, and ends the process with them: it counts before it ends it
    if Locks.epoch(state.user_id) == epoch do
      :ets.insert(state.credentials, {:credentials, credentials})
      {:reply, :ok, state, idle_timeout()}
    else
      # Locked since the epoch was read. Credentials that are in here are from an
      # unlock after the lock, so they stay, and without them there is nothing to keep
      if credentials(state) == nil,
        do: {:stop, :normal, {:error, :locked}, state},
        else: {:reply, {:error, :locked}, state, idle_timeout()}
    end
  end

  def handle_call({:request, context, request}, _from, state) do
    token = OpenTelemetry.Ctx.attach(context)

    try do
      {:reply, run(credentials(state), request), state, idle_timeout()}
    after
      OpenTelemetry.Ctx.detach(token)
    end
  end

  # Not used for the window: it forgets the credentials by ending
  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  # Nothing else is expected. The timer of the process is gone with any message,
  # so this starts the window again, which is better than never ending it
  def handle_info(_message, state), do: {:noreply, state, idle_timeout()}

  @impl true
  def format_status(status), do: Map.replace(status, :message, :redacted)

  defp credentials(state) do
    case :ets.lookup(state.credentials, :credentials) do
      [{:credentials, credentials}] -> credentials
      [] -> nil
    end
  end

  defp run(nil, _request), do: {:error, :locked}

  defp run(credentials, {:list_all_invoices, params, opts}),
    do: Elorus.list_all_invoices(credentials, params, opts)

  defp run(credentials, {:invoice_pdf, id}), do: Elorus.invoice_pdf(credentials, id)

  defp idle_timeout do
    :ike_emails
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:idle_timeout, :timer.minutes(15))
  end
end
