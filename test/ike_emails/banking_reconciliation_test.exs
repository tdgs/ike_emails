defmodule IkeEmails.BankingReconciliationTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmails.Invoicing

  setup :create_user_scope

  describe "status/1" do
    test "is invoiced for a transaction with an invoice", %{scope: scope} do
      transaction = transaction_fixture(scope)
      :ok = Invoicing.attach(scope, invoice_fixture(scope), transaction)

      assert scope |> Banking.get_transaction!(transaction.id) |> Banking.status() == :invoiced
    end

    test "is exempt for a transaction marked as needing no invoice", %{scope: scope} do
      {:ok, transaction} =
        Banking.mark_no_invoice(scope, transaction_fixture(scope), "tax payment")

      assert Banking.status(%{transaction | invoices: []}) == :exempt
    end

    test "is missing for money out without invoice or mark", %{scope: scope} do
      assert transaction_fixture(scope, %{"amount" => "-9.00"}) |> Banking.status() == :missing
    end

    test "is income for money in without invoice or mark", %{scope: scope} do
      assert transaction_fixture(scope, %{"amount" => "594.40"}) |> Banking.status() == :income
    end

    test "needs the invoices to be loaded", %{scope: scope} do
      transaction = Repo.get!(Banking.Transaction, transaction_fixture(scope).id)

      assert_raise ArgumentError, fn -> Banking.status(transaction) end
    end
  end

  describe "mark_no_invoice/3 and clear_no_invoice/2" do
    test "take an optional reason", %{scope: scope} do
      assert {:ok, %{no_invoice: true, no_invoice_note: nil}} =
               Banking.mark_no_invoice(scope, transaction_fixture(scope))

      assert {:ok, %{no_invoice: true, no_invoice_note: nil}} =
               Banking.mark_no_invoice(scope, transaction_fixture(scope), "  ")
    end

    test "limit the length of the reason", %{scope: scope} do
      assert {:error, changeset} =
               Banking.mark_no_invoice(
                 scope,
                 transaction_fixture(scope),
                 String.duplicate("a", 1001)
               )

      assert %{no_invoice_note: ["should be at most 1000 character(s)"]} = errors_on(changeset)
    end

    test "a transaction marked without a reason is exempt", %{scope: scope} do
      {:ok, transaction} = Banking.mark_no_invoice(scope, transaction_fixture(scope))

      assert Banking.status(%{transaction | invoices: []}) == :exempt
    end

    test "refuse a transaction that has invoices", %{scope: scope} do
      transaction = transaction_fixture(scope)
      :ok = Invoicing.attach(scope, invoice_fixture(scope), transaction)
      transaction = Banking.get_transaction!(scope, transaction.id)

      assert {:error, :has_invoices} = Banking.mark_no_invoice(scope, transaction, "tax")
    end

    test "mark and clear", %{scope: scope} do
      transaction = transaction_fixture(scope)

      assert {:ok, %{no_invoice: true, no_invoice_note: "dividend"} = marked} =
               Banking.mark_no_invoice(scope, transaction, "dividend")

      assert {:ok, %{no_invoice: false, no_invoice_note: nil}} =
               Banking.clear_no_invoice(scope, marked)
    end
  end

  describe "list_transactions_for_month/3" do
    test "includes the first and the last day and nothing outside the month", %{scope: scope} do
      for date <- ~w(2026-09-30 2026-10-01 2026-10-15 2026-10-31 2026-11-01) do
        transaction_fixture(scope, %{"date" => date, "value_date" => date})
      end

      dates =
        scope
        |> Banking.list_transactions_for_month(2026, 10)
        |> Enum.map(&Date.to_iso8601(&1.date))

      assert dates == ~w(2026-10-01 2026-10-15 2026-10-31)
    end

    test "works across the year end", %{scope: scope} do
      transaction_fixture(scope, %{"date" => "2025-12-31"})
      transaction_fixture(scope, %{"date" => "2026-01-01"})

      assert [%{date: ~D[2025-12-31]}] = Banking.list_transactions_for_month(scope, 2025, 12)
      assert [%{date: ~D[2026-01-01]}] = Banking.list_transactions_for_month(scope, 2026, 1)
    end

    test "preloads the invoices, and a transfer comes before its fee", %{scope: scope} do
      transfer =
        transaction_fixture(scope, %{
          "transaction_id" => "T1",
          "description" => "TRANSFER",
          "amount" => "-100"
        })

      fee =
        transaction_fixture(scope, %{
          "transaction_id" => "T1",
          "description" => "FEE",
          "amount" => "-9"
        })

      :ok = Invoicing.attach(scope, invoice_fixture(scope), fee)

      assert [first, second] = Banking.list_transactions_for_month(scope, 2026, 10)
      assert {first.id, second.id} == {transfer.id, fee.id}
      assert first.invoices == []
      assert [_] = second.invoices
    end
  end

  test "months_with_transactions/1 lists the months latest first", %{scope: scope} do
    for date <- ~w(2026-08-03 2026-10-12 2026-10-20 2026-09-30) do
      transaction_fixture(scope, %{"date" => date})
    end

    assert Banking.months_with_transactions(scope) == [
             ~D[2026-10-01],
             ~D[2026-09-01],
             ~D[2026-08-01]
           ]
  end

  test "month_summary/1 counts the statuses and totals what is missing", %{scope: scope} do
    invoiced = transaction_fixture(scope, %{"amount" => "-50"})
    :ok = Invoicing.attach(scope, invoice_fixture(scope), invoiced)

    {:ok, exempt} =
      Banking.mark_no_invoice(scope, transaction_fixture(scope, %{"amount" => "-1157.98"}), "tax")

    # Money in with an invoice is invoiced, but it is no payment
    invoiced_income = transaction_fixture(scope, %{"amount" => "300"})
    :ok = Invoicing.attach(scope, invoice_fixture(scope), invoiced_income)

    transactions = [
      Banking.get_transaction!(scope, invoiced.id),
      %{exempt | invoices: []},
      transaction_fixture(scope, %{"amount" => "-90.00"}),
      transaction_fixture(scope, %{"amount" => "-4.51"}),
      transaction_fixture(scope, %{"amount" => "594.40"}),
      Banking.get_transaction!(scope, invoiced_income.id)
    ]

    assert Banking.month_summary(transactions) == %{
             invoiced: 2,
             exempt: 1,
             missing: 2,
             income: 1,
             missing_cents: 9451,
             paid_reconciled: 2
           }
  end
end
