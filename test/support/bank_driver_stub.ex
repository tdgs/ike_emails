defmodule IkeEmails.BankDriverStub do
  @moduledoc """
  The bank in the tests, in place of a browser: a scripted `IkeEmails.Bank.Driver`.
  `script/1` says what each operation answers, and every call is sent to the test as
  `{:driver_call, operation, args}`, so that it can tell the order of the calls. The
  operations are `:open`, `:login`, `:fetch_statements`, `:fetch_details`,
  `:list_estatements`, `:fetch_estatement`, `:logout` and `:close`.

  Nothing secret is sent: the `args` of a login are `[:credentials]`, and the IBAN is `:iban`
  wherever it is an argument. The other arguments are as they were given (the options of
  `open`, the days, the ids of the transactions, the id of a statement).

  What an operation answers is its entry in the map that `script/1` takes:

    * a list is a queue: each call takes the next answer, and when it is empty the default
      is the answer
    * a function is called with the arguments of the operation, apart from the session,
      as a list (`[credentials]`, `[iban, days]`, `[iban, ids]`, `[iban]`, `[id]`), and
      what it returns is the answer. It may raise, to test a crash
    * anything else is the answer to every call

  The defaults are a session that opens, a login, a logout and a close that work, details
  for every id asked for (see `details_json/1`), a list of no monthly statements, and
  `{:error, :not_scripted}` for the statements and the PDF, which have no sensible default.

  The script is kept in the process dictionary of the test, so the crawl must run in the
  test process, and tests that use it can be async.
  """

  @behaviour IkeEmails.Bank.Driver

  @doc """
  Sets what the operations answer, see the module. A test must call it before it runs
  anything that uses the driver.
  """
  def script(answers \\ %{}) when is_map(answers) do
    Process.put(__MODULE__, %{test: self(), answers: answers})
    :ok
  end

  @doc """
  The answer of the bank for the details of the transaction `id`, as JSON text: its one
  statement with a detail whose sender is `"SENDER <id>"`.
  """
  def details_json(id) do
    Jason.encode!(%{
      "ResultCode" => 0,
      "Statements" => [
        %{
          "TransactionUN" => id,
          "StatementDetails" => [
            %{
              "ConversionDetails" => "",
              "SenderDetails" => "SENDER #{id}",
              "AdditionalInformation" => ""
            }
          ]
        }
      ]
    })
  end

  @doc """
  An answer of `fetch_details` for `ids`: an entry for each one, but for those in `:failed`,
  which are counted as failed and have none. With `:stopped` (401 or 403) the bank refused
  after them.
  """
  def details(ids, opts \\ []) do
    failed = Keyword.get(opts, :failed, [])

    {:ok,
     %{
       entries: for(id <- ids -- failed, do: %{id: id, json: details_json(id)}),
       failed: length(failed),
       stopped: Keyword.get(opts, :stopped)
     }}
  end

  @impl true
  def open(opts), do: call(:open, [opts])

  @impl true
  def login(_session, credentials), do: call(:login, [credentials], [:credentials])

  @impl true
  def fetch_statements(_session, iban, days) do
    call(:fetch_statements, [iban, days], [:iban, days])
  end

  @impl true
  def fetch_details(_session, iban, ids), do: call(:fetch_details, [iban, ids], [:iban, ids])

  @impl true
  def list_estatements(_session, iban), do: call(:list_estatements, [iban], [:iban])

  @impl true
  def fetch_estatement(_session, id), do: call(:fetch_estatement, [id])

  @impl true
  def logout(_session), do: call(:logout, [])

  @impl true
  def close(_session), do: call(:close, [])

  defp call(operation, args, shown \\ nil) do
    state = state()
    send(state.test, {:driver_call, operation, shown || args})

    {answer, answers} = next_answer(state.answers, operation)
    Process.put(__MODULE__, %{state | answers: answers})

    case answer do
      answer when is_function(answer, 1) -> answer.(args)
      answer -> answer
    end
  end

  defp state do
    Process.get(__MODULE__) ||
      raise "the driver was used in a process that has no script, see IkeEmails.BankDriverStub"
  end

  defp next_answer(answers, operation) do
    case Map.fetch(answers, operation) do
      {:ok, [answer | rest]} -> {answer, Map.put(answers, operation, rest)}
      {:ok, []} -> {default(operation), answers}
      {:ok, answer} -> {answer, answers}
      :error -> {default(operation), answers}
    end
  end

  defp default(:open), do: {:ok, :stub_session}
  defp default(:login), do: :ok
  defp default(:fetch_statements), do: {:error, :not_scripted}
  defp default(:fetch_details), do: fn [_iban, ids] -> details(ids) end
  defp default(:list_estatements), do: {:ok, ~s({"ResultCode": 0, "EStatements": []})}
  defp default(:fetch_estatement), do: {:error, :not_scripted}
  defp default(:logout), do: :ok
  defp default(:close), do: :ok
end
