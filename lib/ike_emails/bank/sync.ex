defmodule IkeEmails.Bank.Sync do
  @moduledoc """
  Reads the transactions and the latest monthly statement of an account in myAlpha, for the
  credentials of a user. It holds what a crawl does apart from how the bank is reached
  (that is a `IkeEmails.Bank.Driver`, which knows about the browser): the retries of the
  login, the details asked for in batches, what to do when the bank refuses, and which rows
  can be trusted. It is ported from the crawler written in Gleam, and its tests run it
  against a scripted driver, so there is no browser in them.

  `crawl/2` returns an `IkeEmails.Bank.Crawl` and stores nothing, so that whoever runs it
  decides where the rows go. It keeps no state and runs in the process that calls it. It
  takes minutes, so it is not for a request. It never logs: the errors it returns are
  atoms and tuples of atoms that hold nothing from the bank and nothing of the credentials,
  and the credentials are only handed to the driver.

  A crawl does this, in this order:

    1. Opens the driver. From here on it is closed whatever happens.
    2. Logs in, up to 3 times. The bank allows one session at a time: when one is open it
       ends that session and refuses the login in progress, which the driver tells as
       `{:error, :session_in_use}`, so the crawl waits 2 seconds and logs in again. Any
       other refusal is returned at once and not tried again, since a password that was
       refused and is tried again can lock the account. No logout is tried after a login
       that failed, as there is no session to end.
    3. From a login that worked, everything below is covered: the driver is asked to log
       out whatever happens, even when the crawl raises, because the bank refuses the next
       login while a session is open. A logout that fails is ignored, there is nothing to
       report and it never hides the result of the crawl.
    4. Reads the statements of the last `:days` days, and checks that their amounts add up
       to how much the balance moved (see `IkeEmails.Bank.Alpha.Reconcile`). A crawl never
       goes on from statements that do not add up, and returns no rows from them.
    5. Reads the details of the transactions in batches of 20, in the order of the
       statements. Only the lines that list no detail of their own are asked for: the bank
       lists them for all but the most recent lines, and a line's own detail wins over the
       one the call gives, so the answer for the others would not be used. (The crawler in
       Gleam asked for every transaction.) A transaction is asked for once even when
       several lines have its id.
    6. Makes the rows (see `IkeEmails.Bank.Alpha.Rows`). A line without a detail of its own
       whose transaction has no valid details, because the bank gave none or the crawl
       never asked for them, is not turned into a row: the API of the app keeps the first
       copy of a transaction, so one stored without its details would stay that way. Its id
       is in `skipped` instead, once, and `details_failed` counts the ids in it. They are
       counted from the ids themselves, not from what the driver says it failed, so that
       the ones never asked for are counted too. The next crawl reads them again. A line
       whose date is not a day written as `d/M/yyyy` is not turned into a row either, but
       that is the fault of that one line and not of the crawl: the other rows are made, the
       statement is read, and the id of the line is in `rejected`. The next crawl rejects it
       again, so whoever runs the crawl has to show a `rejected` that is not empty.
    7. Reads the PDF of the latest monthly statement, only when the bank did not stop the
       crawl.

  When the bank answers a request for details with 401 (the session ended) or 403 (the
  bank blocks the calls), the crawl stops asking: going on only makes a block worse. The
  rows it has details for are returned all the same, with `stopped` set to the status, no
  statement, and the ids it did not get to in `skipped`. See `IkeEmails.Bank.Crawl.complete?/1`.

  A statement that is `nil` in the result means that the bank has issued none yet, that the
  crawl was stopped, or that it could not be read (the list could not be read, the PDF could
  not be fetched or was not a PDF). They are not told apart: the rows are good whichever it
  was, and a missing statement is picked up by the next crawl. The Gleam crawler failed the
  program after it had written everything else, and this is the closest equivalent.

  Options of `crawl/2`:

    * `:driver` - the module that reaches the bank. By default the one in the configuration,
      `config :ike_emails, IkeEmails.Bank, driver: MyDriver`
    * `:days` - how far back to read, 365 by default
    * `:sleep` - a function of one argument that waits that many milliseconds, `&Process.sleep/1`
      by default. The tests pass one that does not wait
    * `:driver_opts` - handed to `c:IkeEmails.Bank.Driver.open/1`

  The errors are:

    * `{:open, reason}` - the driver could not be started
    * `{:login, reason}` - the login did not work. The reasons are those of
      `c:IkeEmails.Bank.Driver.login/2`: `:bad_credentials`, `:session_in_use` (on the third
      attempt), `{:challenge, kind}` and `:timeout`, or any other the driver gives
    * `{:statements, reason}` - the statements could not be had. The reason is the driver's,
      or `:unexpected_response` when the bank's answer is not what
      `IkeEmails.Bank.Alpha.Statements` reads, or `:balances_missing` or `:mismatch` from the
      check against the balances
    * `{:details, reason}` - a request for details failed in the driver without a status
      from the bank (a page that is gone, a timeout), or the answers cannot be read
      (`:unexpected_response`). The crawl gives up and returns nothing, as it has no status
      to say it was stopped with. The rows are not lost: the next crawl reads them again

  An exception raised in the driver, or by the crawl, is not turned into an error: the
  driver is logged out of and closed, and the exception goes on, so that the caller sees
  what happened.
  """

  alias IkeEmails.Bank.Alpha.Details
  alias IkeEmails.Bank.Alpha.EStatements
  alias IkeEmails.Bank.Alpha.Pdf
  alias IkeEmails.Bank.Alpha.Reconcile
  alias IkeEmails.Bank.Alpha.Rows
  alias IkeEmails.Bank.Alpha.Statements
  alias IkeEmails.Bank.Credentials
  alias IkeEmails.Bank.Crawl

  @default_days 365
  @login_attempts 3
  @session_in_use_wait 2_000
  @details_batch 20

  @type error ::
          {:open, term()}
          | {:login, term()}
          | {:statements, term()}
          | {:details, term()}

  @doc """
  Reads the account of `credentials` from the bank. See the module for what it does, the
  options and the errors.
  """
  @spec crawl(Credentials.t(), keyword()) :: {:ok, Crawl.t()} | {:error, error()}
  def crawl(%Credentials{} = credentials, opts \\ []) do
    settings = settings(opts)

    case settings.driver.open(settings.driver_opts) do
      {:ok, session} ->
        try do
          log_in_and_read(settings, session, credentials)
        after
          ignoring_failures(fn -> settings.driver.close(session) end)
        end

      {:error, reason} ->
        {:error, {:open, reason}}
    end
  end

  defp settings(opts) do
    %{
      driver: Keyword.get_lazy(opts, :driver, &configured_driver/0),
      days: Keyword.get(opts, :days, @default_days),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      driver_opts: Keyword.get(opts, :driver_opts, [])
    }
  end

  defp configured_driver do
    :ike_emails |> Application.fetch_env!(IkeEmails.Bank) |> Keyword.fetch!(:driver)
  end

  defp log_in_and_read(settings, session, credentials) do
    with :ok <- log_in(settings, session, credentials, @login_attempts) do
      try do
        read(settings, session, credentials.iban)
      after
        ignoring_failures(fn -> settings.driver.logout(session) end)
      end
    end
  end

  defp log_in(settings, session, credentials, attempts_left) do
    case settings.driver.login(session, credentials) do
      :ok ->
        :ok

      {:error, :session_in_use} when attempts_left > 1 ->
        settings.sleep.(@session_in_use_wait)
        log_in(settings, session, credentials, attempts_left - 1)

      {:error, reason} ->
        {:error, {:login, reason}}
    end
  end

  # What is left of a failure of the logout or the close is nothing that the caller can
  # act on, and it must not take the place of the result or of the exception of the crawl
  defp ignoring_failures(fun) do
    _ = fun.()
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp read(settings, session, iban) do
    with {:ok, statements} <- statements(settings, session, iban),
         {:ok, fetched} <- details(settings, session, iban, statements) do
      {rows, rejected} = rows(statements, fetched)

      {:ok,
       %Crawl{
         rows: rows,
         statement: statement(settings, session, iban, fetched.stopped),
         details_failed: length(fetched.skipped),
         skipped: fetched.skipped,
         rejected: rejected,
         stopped: fetched.stopped
       }}
    end
  end

  defp statements(settings, session, iban) do
    with {:ok, body} <- settings.driver.fetch_statements(session, iban, settings.days),
         {:ok, parsed} <- Statements.parse(body),
         :ok <- Reconcile.check(parsed) do
      {:ok, parsed.statements}
    else
      {:error, reason} -> {:error, {:statements, reason}}
    end
  end

  # `skipped` are the ids that need details and have none, in the order of the statements
  defp details(settings, session, iban, statements) do
    ids = ids_needing_details(statements)

    with {:ok, responses, stopped} <- fetch_details(settings, session, iban, ids),
         {:ok, details} <- Details.parse(responses) do
      {:ok,
       %{
         details: details,
         skipped: Enum.reject(ids, &Map.has_key?(details, &1)),
         stopped: stopped
       }}
    else
      {:error, reason} -> {:error, {:details, reason}}
    end
  end

  defp ids_needing_details(statements) do
    statements
    |> Enum.filter(&is_nil(&1.detail))
    |> Enum.map(& &1.transaction_id)
    |> Enum.uniq()
  end

  # The answers of the bank as JSON text by id, and the status that stopped the asking, if any
  defp fetch_details(settings, session, iban, ids) do
    ids
    |> Enum.chunk_every(@details_batch)
    |> Enum.reduce_while({:ok, %{}, nil}, fn batch, {:ok, responses, nil} ->
      case settings.driver.fetch_details(session, iban, batch) do
        {:ok, %{entries: entries, stopped: nil}} ->
          {:cont, {:ok, add_entries(responses, entries), nil}}

        {:ok, %{entries: entries, stopped: status}} when status in [401, 403] ->
          {:halt, {:ok, add_entries(responses, entries), status}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp add_entries(responses, entries) do
    Enum.reduce(entries, responses, fn %{id: id, json: json}, responses ->
      Map.put(responses, id, json)
    end)
  end

  # A line with a detail of its own is a row whatever happened to the call for its id. The
  # rows and the ids of the lines whose date cannot be read
  defp rows(statements, %{details: details, skipped: skipped}) do
    skipped = MapSet.new(skipped)

    trusted =
      Enum.reject(statements, fn statement ->
        is_nil(statement.detail) and MapSet.member?(skipped, statement.transaction_id)
      end)

    {:ok, rows, rejected} = Rows.build(trusted, details)
    {rows, rejected}
  end

  defp statement(_settings, _session, _iban, stopped) when not is_nil(stopped), do: nil

  defp statement(settings, session, iban, nil) do
    with {:ok, body} <- settings.driver.list_estatements(session, iban),
         {:ok, estatements} <- EStatements.parse(body),
         {:ok, latest} <- EStatements.latest(estatements),
         {:ok, file} <- settings.driver.fetch_estatement(session, latest.id),
         {:ok, pdf} <- Pdf.decode(file) do
      %{month: EStatements.month(latest), file_name: EStatements.file_name(latest), pdf: pdf}
    else
      {:error, _reason} -> nil
    end
  end
end
