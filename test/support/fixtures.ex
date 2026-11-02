defmodule IkeEmails.Fixtures do
  @moduledoc """
  Builds users, transactions, invoices and statements for the tests. The
  transactions, invoices and statements are made for the user of a scope, see
  `user_scope_fixture/1`.
  """

  alias IkeEmails.Accounts
  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Banking
  alias IkeEmails.Invoicing
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
        "issuer_vat" => "EL 987u4š1",
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

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
