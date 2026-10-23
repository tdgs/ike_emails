defmodule IkeEmails.Fixtures do
  @moduledoc """
  Builds transactions and invoices for the tests.
  """

  alias IkeEmails.Banking
  alias IkeEmails.Invoicing

  def transaction_fixture(attrs \\ %{}) do
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

    {:ok, _status, transaction} = Banking.create_transaction(attrs)
    Banking.get_transaction!(transaction.id)
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

  def invoice_fixture(attrs \\ %{}, opts \\ []) do
    {:ok, invoice} =
      Invoicing.create_invoice(invoice_attrs(attrs), pdf_fixture(), "invoice.pdf", opts)

    invoice
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
