defmodule IkeEmailsWeb.ReconciliationLiveTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  alias IkeEmails.Banking
  alias IkeEmails.Invoicing
  alias IkeEmails.Storage.InMemory

  setup :register_and_log_in_user

  defp row(transaction), do: "#transactions-#{transaction.id}"

  describe "the month" do
    test "defaults to the latest month with transactions", %{conn: conn, scope: scope} do
      september = transaction_fixture(scope, %{"date" => "2026-09-14"})
      october = transaction_fixture(scope, %{"date" => "2026-10-12"})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#month-title", "October 2026")
      assert has_element?(view, row(october))
      refute has_element?(view, row(september))
    end

    test "is chosen with the month param, and falls back when it is not one", %{
      conn: conn,
      scope: scope
    } do
      september = transaction_fixture(scope, %{"date" => "2026-09-14"})
      october = transaction_fixture(scope, %{"date" => "2026-10-12"})

      {:ok, view, _html} = live(conn, ~p"/?month=2026-09")
      assert has_element?(view, "#month-title", "September 2026")
      assert has_element?(view, row(september))
      refute has_element?(view, row(october))

      {:ok, view, _html} = live(conn, ~p"/?month=nonsense")
      assert has_element?(view, "#month-title", "October 2026")
    end

    test "moves to the previous and next month", %{conn: conn, scope: scope} do
      september = transaction_fixture(scope, %{"date" => "2026-09-14"})
      transaction_fixture(scope, %{"date" => "2026-10-12"})

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      view |> element("#prev-month") |> render_click()
      assert_patch(view, ~p"/?month=2026-09")
      assert has_element?(view, row(september))

      view |> element("#next-month") |> render_click()
      assert_patch(view, ~p"/?month=2026-10")
    end

    test "jumps to a month from the list", %{conn: conn, scope: scope} do
      september = transaction_fixture(scope, %{"date" => "2026-09-14"})
      transaction_fixture(scope, %{"date" => "2026-10-12"})

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      view |> form("#month-form", %{"month" => "2026-09"}) |> render_change()

      assert_patch(view, ~p"/?month=2026-09")
      assert has_element?(view, row(september))
    end

    test "says when it has no transactions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?month=2026-01")

      assert has_element?(view, "#transactions-empty")
      refute has_element?(view, "#reconciled-progress")
    end
  end

  describe "the month report" do
    test "is downloaded from the month that has a statement", %{conn: conn, scope: scope} do
      statement_fixture(scope, "2026-10")

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      assert has_element?(view, "a#download-month-report[href='/reports/2026-10']")

      view |> element("#next-month") |> render_click()
      assert_patch(view, ~p"/?month=2026-11")
      assert has_element?(view, "button#download-month-report[disabled]")
    end

    test "cannot be downloaded from a month without a statement", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      assert has_element?(view, "button#download-month-report[disabled]")
      refute has_element?(view, "a#download-month-report")
    end
  end

  describe "the transactions" do
    test "show their status", %{conn: conn, scope: scope} do
      missing = transaction_fixture(scope, %{"amount" => "-90.00"})
      income = transaction_fixture(scope, %{"amount" => "594.40"})
      invoiced = transaction_fixture(scope, %{"amount" => "-30.00"})
      Invoicing.attach(scope, invoice_fixture(scope), invoiced)

      {:ok, exempt} =
        Banking.mark_no_invoice(
          scope,
          transaction_fixture(scope, %{"amount" => "-5.00"}),
          "bank fee"
        )

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      assert has_element?(view, "#status-#{missing.id}[data-status=missing]")
      assert has_element?(view, "#status-#{income.id}[data-status=income]")
      assert has_element?(view, "#status-#{invoiced.id}[data-status=invoiced]")
      assert has_element?(view, "#status-#{exempt.id}[data-status=exempt]")
    end

    test "summarise the month", %{conn: conn, scope: scope} do
      transaction_fixture(scope, %{"amount" => "-90.00"})
      transaction_fixture(scope, %{"amount" => "-4.51"})
      invoiced = transaction_fixture(scope, %{"amount" => "-30.00"})
      Invoicing.attach(scope, invoice_fixture(scope), invoiced)

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      assert has_element?(view, "#stat-missing", "2")
      assert has_element?(view, "#stat-missing", "94,51 €")
      assert has_element?(view, "#stat-invoiced", "1")
      assert has_element?(view, "#reconciled-count", "1 of 3 payments reconciled")
    end

    test "list their invoices, with a link to the PDF", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)

      invoice =
        invoice_fixture(scope, %{"issuer_name" => "Elorus"}, transaction_ids: [transaction.id])

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      assert has_element?(view, "#{row(transaction)}-invoice-#{invoice.id}", "Elorus")

      assert has_element?(
               view,
               "#{row(transaction)}-invoice-#{invoice.id} a[href='/invoices/#{invoice.id}/pdf']"
             )
    end

    test "can have an invoice detached", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      invoice = invoice_fixture(scope, %{}, transaction_ids: [transaction.id])

      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")
      view |> element("#detach-#{transaction.id}-#{invoice.id}") |> render_click()

      assert has_element?(view, "#status-#{transaction.id}[data-status=missing]")
      refute has_element?(view, "#{row(transaction)}-invoice-#{invoice.id}")
      assert Banking.get_transaction!(scope, transaction.id).invoices == []
      assert Invoicing.get_invoice!(scope, invoice.id)
    end
  end

  describe "marking a transaction as needing no invoice" do
    test "takes an optional reason, and can be undone", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope, %{"amount" => "-1157.98"})
      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      view
      |> form("#no-invoice-form-#{transaction.id}", exempt: %{note: "VAT payment"})
      |> render_submit()

      assert has_element?(view, "#status-#{transaction.id}[data-status=exempt]")
      assert has_element?(view, "#{row(transaction)}-note", "VAT payment")
      assert has_element?(view, "#stat-exempt", "1")
      refute has_element?(view, "#no-invoice-form-#{transaction.id}")

      view |> element("#clear-no-invoice-#{transaction.id}") |> render_click()

      assert has_element?(view, "#status-#{transaction.id}[data-status=missing]")
      transaction = Banking.get_transaction!(scope, transaction.id)
      assert transaction.no_invoice == false
      assert transaction.no_invoice_note == nil
    end

    test "works without a reason", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      view |> form("#no-invoice-form-#{transaction.id}", exempt: %{note: "  "}) |> render_submit()

      assert has_element?(view, "#status-#{transaction.id}[data-status=exempt]")
      assert has_element?(view, "#{row(transaction)}-note")
      assert has_element?(view, "#clear-no-invoice-#{transaction.id}")

      transaction = Banking.get_transaction!(scope, transaction.id)
      assert transaction.no_invoice == true
      assert transaction.no_invoice_note == nil
    end

    test "refuses a transaction that got an invoice meanwhile", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      :ok = Invoicing.attach(scope, invoice_fixture(scope), transaction)

      view
      |> form("#no-invoice-form-#{transaction.id}", exempt: %{note: "tax"})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      assert Banking.get_transaction!(scope, transaction.id).no_invoice == false
    end

    test "refuses a reason that is too long", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/?month=2026-10")

      view
      |> form("#no-invoice-form-#{transaction.id}", exempt: %{note: String.duplicate("a", 1001)})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#status-#{transaction.id}[data-status=missing]")
    end
  end

  describe "adding an invoice to a transaction" do
    test "opens a panel that suggests the amount and currency of the transaction", %{
      conn: conn,
      scope: scope
    } do
      transaction =
        transaction_fixture(scope, %{"amount" => "-193.44", "value_date" => "2026-10-09"})

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#add-invoice-#{transaction.id}") |> render_click()

      assert_patch(view, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")
      assert has_element?(view, "#attach-panel")

      assert has_element?(
               view,
               "#invoice-form input[name='invoice[amount_input]'][value='193,44']"
             )

      assert has_element?(view, "#invoice-form input[name='invoice[currency]'][value=EUR]")
      assert has_element?(view, "#invoice-form input[name='invoice[date]'][value='2026-10-09']")
    end

    test "suggests the foreign currency a charge was converted from", %{conn: conn, scope: scope} do
      transaction =
        transaction_fixture(scope, %{"amount" => "-18.01", "conversion_details" => "20,00 USD"})

      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      assert has_element?(
               view,
               "#invoice-form input[name='invoice[amount_input]'][value='20,00']"
             )

      assert has_element?(view, "#invoice-form input[name='invoice[currency]'][value=USD]")
    end

    test "closing the panel goes back to the month", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      view |> element("#attach-panel-close") |> render_click()

      assert_patch(view, ~p"/?month=2026-10")
      refute has_element?(view, "#attach-panel")
    end

    test "uploads a PDF and matches the new invoice to the transaction", %{
      conn: conn,
      scope: scope
    } do
      transaction = transaction_fixture(scope)
      pdf = pdf_fixture()
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      upload_pdf(view, "elorus.pdf", pdf)

      view
      |> form("#invoice-form",
        invoice: %{issuer_name: "Elorus", issuer_vat: "EL987u4�1", number: "42"}
      )
      |> render_submit()

      assert_patch(view, ~p"/?month=2026-10")
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      assert has_element?(view, "#{row(transaction)}", "Elorus")
      assert render(view) =~ "Invoice added."

      assert [invoice] = Banking.get_transaction!(scope, transaction.id).invoices
      assert invoice.amount_cents == 19_344
      assert invoice.file_name == "elorus.pdf"
      assert {^pdf, "application/pdf"} = InMemory.get(invoice.file_key)
    end

    test "needs the PDF", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      view |> form("#invoice-form", invoice: %{issuer_name: "Elorus"}) |> render_submit()

      assert has_element?(view, "#invoice-form-pdf-error")
      assert Banking.get_transaction!(scope, transaction.id).invoices == []
    end

    test "rejects a file that is not a PDF", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      upload_pdf(view, "invoice.pdf", "this is not a pdf")
      view |> form("#invoice-form", invoice: %{issuer_name: "Elorus"}) |> render_submit()

      assert has_element?(view, "#invoice-form-pdf-error", "not a PDF")
      assert Banking.get_transaction!(scope, transaction.id).invoices == []
    end

    test "shows the mistakes of the form and keeps the file for the next try", %{
      conn: conn,
      scope: scope
    } do
      transaction = transaction_fixture(scope)
      pdf = pdf_fixture()
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      upload_pdf(view, "elorus.pdf", pdf)

      html = view |> form("#invoice-form", invoice: %{issuer_name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"
      assert Banking.get_transaction!(scope, transaction.id).invoices == []

      view |> form("#invoice-form", invoice: %{issuer_name: "Elorus"}) |> render_submit()

      assert_patch(view, ~p"/?month=2026-10")
      assert [_invoice] = Banking.get_transaction!(scope, transaction.id).invoices
    end

    test "offers to attach the invoice when the same PDF was uploaded before", %{
      conn: conn,
      scope: scope
    } do
      pdf = pdf_fixture()
      {:ok, existing} = Invoicing.create_invoice(scope, invoice_attrs(), pdf, "elorus.pdf")
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      upload_pdf(view, "again.pdf", pdf)
      view |> form("#invoice-form", invoice: %{issuer_name: "Elorus"}) |> render_submit()

      assert has_element?(view, "#duplicate-notice", "Elorus")
      assert Banking.get_transaction!(scope, transaction.id).invoices == []

      view |> element("#attach-duplicate") |> render_click()

      assert_patch(view, ~p"/?month=2026-10")
      assert [%{id: id}] = Banking.get_transaction!(scope, transaction.id).invoices
      assert id == existing.id
    end
  end

  describe "attaching an existing invoice" do
    test "lists the invoices that could belong to the transaction", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope, %{"amount" => "-193.44"})
      exact = invoice_fixture(scope, %{"amount_input" => "193,44"})
      other = invoice_fixture(scope, %{"amount_input" => "5", "issuer_name" => "Linode"})
      attached = invoice_fixture(scope, %{}, transaction_ids: [transaction.id])

      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      assert has_element?(view, "#suggestions-#{exact.id}", "same amount")
      assert has_element?(view, "#suggestions-#{other.id}")
      refute has_element?(view, "#suggestions-#{attached.id}")
    end

    test "shows the receiver of an invoice that was issued, and finds it by it", %{
      conn: conn,
      scope: scope
    } do
      transaction = transaction_fixture(scope, %{"amount" => "100.00"})
      issued = invoice_fixture(scope, %{"issuer_name" => "Me", "receiver_name" => "Acme Inc."})
      other = invoice_fixture(scope, %{"issuer_name" => "Linode"})

      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")
      assert has_element?(view, "#suggestions-#{issued.id}", "Acme Inc.")
      refute has_element?(view, "#suggestions-#{other.id}", "→")

      view |> form("#suggestion-search", %{"q" => "acme"}) |> render_change()

      assert has_element?(view, "#suggestions-#{issued.id}")
      refute has_element?(view, "#suggestions-#{other.id}")
    end

    test "narrows them by search", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      linode = invoice_fixture(scope, %{"issuer_name" => "Linode"})
      github = invoice_fixture(scope, %{"issuer_name" => "GitHub"})

      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")
      view |> form("#suggestion-search", %{"q" => "git"}) |> render_change()

      assert has_element?(view, "#suggestions-#{github.id}")
      refute has_element?(view, "#suggestions-#{linode.id}")
    end

    test "ignores a search that arrives after the panel was closed", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      render_patch(view, ~p"/?month=2026-10")
      refute has_element?(view, "#suggestion-search")

      assert render_hook(view, "search_suggestions", %{"q" => "git"})
      assert Process.alive?(view.pid)
    end

    test "matches the chosen invoice to the transaction", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      invoice = invoice_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")

      view |> element("#attach-existing-#{invoice.id}") |> render_click()

      assert_patch(view, ~p"/?month=2026-10")
      assert has_element?(view, "#status-#{transaction.id}[data-status=invoiced]")
      assert [%{id: id}] = Banking.get_transaction!(scope, transaction.id).invoices
      assert id == invoice.id
    end
  end

  defp upload_pdf(view, name, content) do
    view
    |> file_input("#invoice-form", :pdf, [
      %{name: name, content: content, type: "application/pdf"}
    ])
    |> render_upload(name)
  end
end
