defmodule IkeEmails.Fixtures do
  @moduledoc """
  Builds users, transactions, invoices, statements and settings for the tests. The
  transactions, invoices, statements and settings are made for the user of a scope,
  see `user_scope_fixture/1`.
  """

  alias IkeEmails.Accounts
  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Banking
  alias IkeEmails.Elorus.Connection
  alias IkeEmails.Elorus.Credentials
  alias IkeEmails.Invoicing
  alias IkeEmails.Settings
  alias IkeEmails.Statements

  @doc """
  A user, with the password `valid_user_password/0`.
  """
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{email: "user#{n}@example.com", password: valid_user_password()}
    {:ok, user} = defaults |> Map.merge(Map.new(attrs)) |> Accounts.register_user()

    user
  end

  def valid_user_password, do: "a valid password 123"

  @doc """
  The scope of a user, a new one unless given.
  """
  def user_scope_fixture(user \\ nil), do: Scope.for_user(user || user_fixture())

  def transaction_fixture(%Scope{} = scope, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          "date" => "2026-10-12",
          "value_date" => "2026-10-12",
          "description" => "ELORUS #{n}",
          "branch" => "99",
          "transaction_id" => "2026101209935#{n}",
          "amount" => "-193.44"
        },
        stringify(attrs)
      )

    {:ok, _status, transaction} = Banking.create_transaction(scope, attrs)
    Banking.get_transaction!(scope, transaction.id)
  end

  @doc """
  A PDF that no other call returns, as objects are stored under the hash of their bytes.
  """
  def pdf_fixture do
    "%PDF-1.4\n% test invoice #{System.unique_integer([:positive])}\n%%EOF\n"
  end

  def invoice_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        "amount_input" => "193,44",
        "currency" => "EUR",
        "date" => "2026-10-09",
        "issuer_name" => "Elorus",
        "issuer_vat" => "EL 094.019.245",
        "number" => "2026-0042"
      },
      stringify(attrs)
    )
  end

  def invoice_fixture(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    {:ok, invoice} =
      Invoicing.create_invoice(scope, invoice_attrs(attrs), pdf_fixture(), "invoice.pdf", opts)

    invoice
  end

  def statement_fixture(%Scope{} = scope, month \\ "2026-10") do
    {:ok, :created, statement} =
      Statements.put_statement(scope, month, pdf_fixture(), "statement.pdf")

    statement
  end

  @doc """
  Saves the settings of the user: the business `"Test Business"` with the VAT
  number `"EL099999999"`, and the Elorus organization `"1000000243015421"`, with
  the API key `"test-elorus-token"` sealed with the password of the user. The
  `attrs` are those of `IkeEmails.Settings.update_settings/2`.

  Options: `:token`, to seal another API key, or none with `nil`, and `:password`,
  of a user that was not made with `valid_user_password/0`.

  Returns the settings as `IkeEmails.Settings.get_settings/1` does.
  """
  def settings_fixture(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    attrs =
      Map.merge(
        %{
          "business_name" => "Test Business",
          "business_vat" => "EL099999999",
          "elorus_organization_id" => "1000000243015421",
          "elorus_demo" => "false"
        },
        stringify(attrs)
      )

    {:ok, _settings} = Settings.update_settings(scope, attrs)

    if token = Keyword.get(opts, :token, "test-elorus-token") do
      password = Keyword.get(opts, :password, valid_user_password())
      {:ok, _settings} = Settings.set_elorus_token(scope, token, password)
    end

    Settings.get_settings(scope)
  end

  @doc """
  The credentials `settings_fixture/3` saves, as they are when they are opened.
  """
  def elorus_credentials_fixture(attrs \\ []) do
    struct!(
      %Credentials{
        api_token: "test-elorus-token",
        organization_id: "1000000243015421",
        demo: false
      },
      attrs
    )
  end

  @doc """
  Saves the settings of the user of the `scope` in the context (`settings_fixture/1`)
  and unlocks their Elorus credentials, so that the calls to Elorus work. Use it as
  `setup :configure_settings`, after the setup that makes the scope. The `settings`
  are in the context, and the credentials are locked again at the end of the test.

  The requests to Elorus are made by the process of `IkeEmails.Elorus.Connection`,
  not by the test, and a `Req.Test` stub of the test (`IkeEmails.ElorusStub`) is only
  found by the processes the test started, unless the stubs are shared. So this
  shares them, and the test cannot be async: only one test at a time owns the stubs.
  """
  def configure_settings(%{scope: %Scope{} = scope} = context) do
    if context[:async] do
      raise ArgumentError,
            "configure_settings/1 shares the Req.Test stubs, as the requests to Elorus " <>
              "are made by another process: the test cannot be async"
    end

    :ok = Req.Test.set_req_test_to_shared(context)

    settings = settings_fixture(scope)
    :ok = Connection.put_credentials(scope, elorus_credentials_fixture())
    ExUnit.Callbacks.on_exit(fn -> Connection.lock(scope) end)

    %{settings: settings}
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
