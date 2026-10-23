defmodule IkeEmailsWeb.InvoiceLiveTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures
  import Phoenix.LiveViewTest

  alias IkeEmails.Invoicing
  alias IkeEmails.Storage.InMemory

  describe "the list" do
    test "shows the invoices with their PDF and the transactions they are matched to", %{
      conn: conn
    } do
      transaction = transaction_fixture(%{"description" => "ELORUS PAYMENT"})
      matched = invoice_fixture(%{"issuer_name" => "Elorus"}, transaction_ids: [transaction.id])

      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#invoices-#{matched.id}", "Elorus")
      assert has_element?(view, "#invoices-#{matched.id}", "193,44 €")
      assert has_element?(view, "#pdf-#{matched.id}[href='/invoices/#{matched.id}/pdf']")

      assert has_element?(
               view,
               "#invoices-#{matched.id}-transaction-#{transaction.id}",
               "ELORUS PAYMENT"
             )

      refute has_element?(view, "#unmatched-#{matched.id}")
    end

    test "flags the invoices that are not matched to a transaction", %{conn: conn} do
      unmatched = invoice_fixture()

      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#unmatched-#{unmatched.id}")
    end

    test "is searched by issuer", %{conn: conn} do
      github = invoice_fixture(%{"issuer_name" => "GitHub"})
      linode = invoice_fixture(%{"issuer_name" => "Linode"})

      {:ok, view, _html} = live(conn, ~p"/invoices")
      view |> form("#invoice-search", %{"q" => "linode"}) |> render_change()

      assert has_element?(view, "#invoices-#{linode.id}")
      refute has_element?(view, "#invoices-#{github.id}")
    end

    test "says when there are none", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#invoices-empty")
    end

    test "deletes an invoice and its PDF", %{conn: conn} do
      invoice = invoice_fixture()
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#delete-invoice-#{invoice.id}") |> render_click()

      refute has_element?(view, "#invoices-#{invoice.id}")
      refute InMemory.exists?(invoice.file_key)
      assert Invoicing.list_invoices() == []
    end
  end

  describe "a new invoice" do
    test "is uploaded without a transaction, and shows as unmatched", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")
      view |> element("#new-invoice") |> render_click()
      assert_patch(view, ~p"/invoices/new")

      view
      |> file_input("#invoice-form", :pdf, [
        %{name: "gh.pdf", content: pdf_fixture(), type: "application/pdf"}
      ])
      |> render_upload("gh.pdf")

      view
      |> form("#invoice-form",
        invoice: %{
          amount_input: "146,38",
          currency: "usd",
          date: "2026-10-01",
          issuer_name: "GitHub, Inc.",
          issuer_vat: ""
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/invoices")
      assert [invoice] = Invoicing.list_invoices()
      assert {invoice.amount_cents, invoice.currency, invoice.issuer_vat} == {14_638, "USD", nil}
      assert has_element?(view, "#unmatched-#{invoice.id}")
      assert has_element?(view, "#invoices-#{invoice.id}", "146,38 USD")
    end

    test "needs the PDF and a valid form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view |> form("#invoice-form", invoice: %{amount_input: "lots"}) |> render_submit()

      assert has_element?(view, "#invoice-form-pdf-error")
      assert Invoicing.list_invoices() == []
    end
  end

  describe "editing an invoice" do
    test "changes what is typed in", %{conn: conn} do
      invoice = invoice_fixture()
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#edit-invoice-#{invoice.id}") |> render_click()
      assert_patch(view, ~p"/invoices/#{invoice.id}/edit")

      assert has_element?(
               view,
               "#invoice-form input[name='invoice[amount_input]'][value='193,44']"
             )

      view
      |> form("#invoice-form", invoice: %{amount_input: "200", issuer_name: "Elorus SA"})
      |> render_submit()

      assert_patch(view, ~p"/invoices")
      assert has_element?(view, "#invoices-#{invoice.id}", "Elorus SA")
      assert has_element?(view, "#invoices-#{invoice.id}", "200,00 €")
    end

    test "shows what is wrong", %{conn: conn} do
      invoice = invoice_fixture()
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      html = view |> form("#invoice-form", invoice: %{amount_input: "lots"}) |> render_submit()

      assert html =~ "is invalid"
      assert Invoicing.get_invoice!(invoice.id).amount_cents == 19_344
    end
  end
end
