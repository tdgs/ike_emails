defmodule IkeEmails.Bank.Driver do
  @moduledoc """
  The operations of the bank that a crawl needs, apart from how they are done. The real
  driver (`IkeEmails.Bank.Driver.Chrome`) logs in with a browser and calls the bank's own
  endpoints from inside its page; the tests use a scripted one, which is why a crawl
  (`IkeEmails.Bank.Sync`) can be tested without a browser. The driver is set in the
  configuration:

      config :ike_emails, IkeEmails.Bank, driver: MyDriver

  A `session` is whatever the driver needs to remember (a browser and a page); the caller
  only passes it back. Every function returns `{:error, reason}` for a failure, where the
  reason is an atom or a tuple that holds nothing from the bank: no text of a page, no
  response, no credentials. The reasons the crawl tells apart are named below.

  Bodies are returned as the bank sent them, as JSON text, and are parsed by the pure
  modules under `IkeEmails.Bank.Alpha`.
  """

  alias IkeEmails.Bank.Credentials

  @type session :: term()
  @type reason :: atom() | {atom(), term()}

  @typedoc """
  The answer of the bank to the details of up to 20 transactions: `entries` are the ones
  that came back valid, `failed` counts those that did not, and `stopped` is the status
  (401 or 403) with which the bank refused, after which the batch was given up.
  """
  @type details :: %{
          entries: [%{id: String.t(), json: String.t()}],
          failed: non_neg_integer(),
          stopped: nil | 401 | 403
        }

  @doc "Starts the browser (or whatever the driver works with)."
  @callback open(opts :: keyword()) :: {:ok, session()} | {:error, reason()}

  @doc """
  Logs in. It starts from a fresh page every time, so that it can be called again after
  `{:error, :session_in_use}`. The reasons the crawl tells apart:

    * `:bad_credentials` - the bank refused the user name or the password; never retried
    * `:session_in_use` - the bank allows one session at a time and one is open
    * `{:challenge, kind}` - the bank asks for a second factor (kind is an atom)
    * `:timeout` - the bank did not answer in time
  """
  @callback login(session(), Credentials.t()) :: :ok | {:error, reason()}

  @doc "The statements of the last `days` days of the account, as the bank's JSON text."
  @callback fetch_statements(session(), iban :: String.t(), days :: pos_integer()) ::
              {:ok, String.t()} | {:error, reason()}

  @doc "The details of at most 20 transactions."
  @callback fetch_details(session(), iban :: String.t(), ids :: [String.t()]) ::
              {:ok, details()} | {:error, reason()}

  @doc "The list of issued monthly statements (the Copies tab), as the bank's JSON text."
  @callback list_estatements(session(), iban :: String.t()) ::
              {:ok, String.t()} | {:error, reason()}

  @doc "A monthly statement as `%{bytes: size, base64: data}`."
  @callback fetch_estatement(session(), id :: String.t()) ::
              {:ok, %{bytes: non_neg_integer(), base64: String.t()}} | {:error, reason()}

  @doc "Logs out. It is tried after every crawl, whatever happened."
  @callback logout(session()) :: :ok | {:error, reason()}

  @doc "Ends the browser."
  @callback close(session()) :: :ok
end
