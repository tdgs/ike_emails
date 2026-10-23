defmodule IkeEmails.BankingReconciliationTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmails.Invoicing

  describe "status/1" do
    test "is invoiced for a transaction with an invoice" do
      transaction = transaction_fixture()
      :ok = Invoicing.attach(invoice_fixture(), transaction)

      assert transaction.id |> Banking.get_transaction!() |> Banking.status() == :invoiced
    end

    test "is exempt for a transaction marked as needing no invoice" do
      {:ok, transaction} = Banking.mark_no_invoice(transaction_fixture(), "tax payment")

      assert Banking.status(%{transaction | invoices: []}) == :exempt
    end

    test "is missing for money out without invoice or mark" do
      assert transaction_fixture(%{"amount" => "-9.00"}) |> Banking.status() == :missing
    end

    test "is income for money in without invoice or mark" do
      assert transaction_fixture(%{"amount" => "594.40"}) |> Banking.status() == :income
    end

    test "needs the invoices to be loaded" do
      transaction = Repo.get!(Banking.Transaction, transaction_fixture().id)

      assert_raise ArgumentError, fn -> Banking.status(transaction) end
    end
  end

  describe "mark_no_invoice/2 and clear_no_invoice/1" do
    test "take an optional reason" do
      assert {:ok, %{no_invoice: true, no_invoice_note: nil}} =
               Banking.mark_no_invoice(transaction_fixture())

      assert {:ok, %{no_invoice: true, no_invoice_note: nil}} =
               Banking.mark_no_invoice(transaction_fixture(), "  ")
    end

    test "limit the length of the reason" do
      assert {:error, changeset} =
               Banking.mark_no_invoice(transaction_fixture(), String.duplicate("a", 1001))

      assert %{no_invoice_note: ["should be at most 1000 character(s)"]} = errors_on(changeset)
    end

    test "a transaction marked without a reason is exempt" do
      {:ok, transaction} = Banking.mark_no_invoice(transaction_fixture())

      assert Banking.status(%{transaction | invoices: []}) == :exempt
    end

    test "refuse a transaction that has invoices" do
      transaction = transaction_fixture()
      :ok = Invoicing.attach(invoice_fixture(), transaction)
      transaction = Banking.get_transaction!(transaction.id)

      assert {:error, :has_invoices} = Banking.mark_no_invoice(transaction, "tax")
    end

    test "mark and clear" do
      transaction = transaction_fixture()

      assert {:ok, %{no_invoice: true, no_invoice_note: "dividend"} = marked} =
               Banking.mark_no_invoice(transaction, "dividend")

      assert {:ok, %{no_invoice: false, no_invoice_note: nil}} = Banking.clear_no_invoice(marked)
    end
  end

  describe "list_transactions_for_month/2" do
    test "includes the first and the last day and nothing outside the month" do
      for date <- ~w(2026-09-30 2026-10-01 2026-10-15 2026-10-31 2026-11-01) do
        transaction_fixture(%{"date" => date, "value_date" => date})
      end

      dates =
        2026 |> Banking.list_transactions_for_month(10) |> Enum.map(&Date.to_iso8601(&1.date))

      assert dates == ~w(2026-10-01 2026-10-15 2026-10-31)
    end

    test "works across the year end" do
      transaction_fixture(%{"date" => "2025-12-31"})
      transaction_fixture(%{"date" => "2026-01-01"})

      assert [%{date: ~D[2025-12-31]}] = Banking.list_transactions_for_month(2025, 12)
      assert [%{date: ~D[2026-01-01]}] = Banking.list_transactions_for_month(2026, 1)
    end

    test "preloads the invoices, and a transfer comes before its fee" do
      transfer =
        transaction_fixture(%{
          "transaction_id" => "T1",
          "description" => "TRANSFER",
          "amount" => "-100"
        })

      fee =
        transaction_fixture(%{"transaction_id" => "T1", "description" => "FEE", "amount" => "-9"})

      :ok = Invoicing.attach(invoice_fixture(), fee)

      assert [first, second] = Banking.list_transactions_for_month(2026, 10)
      assert {first.id, second.id} == {transfer.id, fee.id}
      assert first.invoices == []
      assert [_] = second.invoices
    end
  end

  test "months_with_transactions/0 lists the months latest first" do
    for date <- ~w(2026-08-03 2026-10-12 2026-10-20 2026-09-30) do
      transaction_fixture(%{"date" => date})
    end

    assert Banking.months_with_transactions() == [~D[2026-10-01], ~D[2026-09-01], ~D[2026-08-01]]
  end

  test "month_summary/1 counts the statuses and totals what is missing" do
    invoiced = transaction_fixture(%{"amount" => "-50"})
    :ok = Invoicing.attach(invoice_fixture(), invoiced)
    {:ok, exempt} = Banking.mark_no_invoice(transaction_fixture(%{"amount" => "-1157.98"}), "tax")

    transactions = [
      Banking.get_transaction!(invoiced.id),
      %{exempt | invoices: []},
      transaction_fixture(%{"amount" => "-90.00"}),
      transaction_fixture(%{"amount" => "-4.51"}),
      transaction_fixture(%{"amount" => "594.40"})
    ]

    assert Banking.month_summary(transactions) == %{
             invoiced: 1,
             exempt: 1,
             missing: 2,
             income: 1,
             missing_cents: 9451
           }
  end
end
