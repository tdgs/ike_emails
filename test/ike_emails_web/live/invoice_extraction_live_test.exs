defmodule IkeEmailsWeb.InvoiceExtractionLiveTest do
  # Not async: the stub that reads the invoices is global
  use IkeEmailsWeb.ConnCase, async: false

  import IkeEmails.Fixtures
  import IkeEmails.InvoiceExtractorStub, only: [found: 0, found: 1]
  import Phoenix.LiveViewTest

  alias IkeEmails.Banking
  alias IkeEmails.InvoiceExtractor
  alias IkeEmails.InvoiceExtractorStub
  alias IkeEmails.Invoicing
  alias IkeEmails.Storage.InMemory

  # The tasks that read the PDFs, and the failures they cause, are logged
  @moduletag :capture_log

  setup :register_and_log_in_user

  defp upload_pdf(view, name, content) do
    view
    |> file_input("#invoice-form", :pdf, [
      %{name: name, content: content, type: "application/pdf"}
    ])
    |> render_upload(name)
  end

  defp extract(view), do: view |> element("#invoice-form-extract") |> render_click()

  # The result arrives from an async task, after the click
  defp wait_for(view, selector, tries \\ 100) do
    cond do
      has_element?(view, selector) -> :ok
      tries == 0 -> flunk("#{selector} did not show up")
      true -> Process.sleep(10) && wait_for(view, selector, tries - 1)
    end
  end

  defp new_invoice_page(conn) do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")
    view
  end

  defp attach_panel(conn, transaction) do
    {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/invoice?month=2026-10")
    view
  end

  for {page, open} <- [{"new invoice", :new_invoice_page}, {"attach panel", :attach_panel}] do
    describe "on the #{page} page" do
      setup %{conn: conn, scope: scope} do
        transaction = transaction_fixture(scope)

        view =
          case unquote(open) do
            :new_invoice_page -> new_invoice_page(conn)
            :attach_panel -> attach_panel(conn, transaction)
          end

        %{view: view, transaction: transaction}
      end

      test "offers to read the PDF only once it is uploaded", %{view: view} do
        refute has_element?(view, "#invoice-form-extract")

        upload_pdf(view, "gh.pdf", pdf_fixture())

        assert has_element?(view, "#invoice-form-extract")
      end

      test "sends nothing before the click", %{view: view} do
        InvoiceExtractorStub.stub({:ok, found()})

        upload_pdf(view, "gh.pdf", pdf_fixture())

        refute_received {:extract_request, _pdf, _prompt, _fields, _model}
      end

      test "fills in the form with what the model found", %{view: view} do
        pdf = pdf_fixture()
        InvoiceExtractorStub.stub({:ok, found()})

        upload_pdf(view, "gh.pdf", pdf)
        extract(view)
        wait_for(view, "#invoice_issuer_name[value='GitHub, Inc.']")

        assert_received {:extract_request, ^pdf, _prompt, _fields, "test:model"}
        assert has_element?(view, "#invoice_amount_input[value='146,38']")
        assert has_element?(view, "#invoice_currency[value=USD]")
        assert has_element?(view, "#invoice_date[value='2026-10-01']")
        assert has_element?(view, "#invoice_issuer_vat[value=EU372041333]")
        assert has_element?(view, "#invoice_number[value=GH-1001]")
        refute has_element?(view, "#invoice-form-extract[disabled]")
        refute has_element?(view, "#invoice-form-extract-error")
      end

      test "still saves the PDF with the invoice afterwards", %{view: view, scope: scope} do
        pdf = pdf_fixture()
        InvoiceExtractorStub.stub({:ok, found()})

        upload_pdf(view, "gh.pdf", pdf)
        extract(view)
        wait_for(view, "#invoice_issuer_name[value='GitHub, Inc.']")

        view |> form("#invoice-form") |> render_submit()

        assert [invoice] = Invoicing.list_invoices(scope)

        assert {invoice.amount_cents, invoice.currency, invoice.issuer_name, invoice.number} ==
                 {14_638, "USD", "GitHub, Inc.", "GH-1001"}

        assert {^pdf, "application/pdf"} = InMemory.get(invoice.file_key)
      end

      test "replaces what was typed, and keeps what the model did not find", %{view: view} do
        InvoiceExtractorStub.stub({:ok, found(%{"number" => nil})})

        upload_pdf(view, "gh.pdf", pdf_fixture())

        view
        |> form("#invoice-form", invoice: %{issuer_name: "Typed", number: "MY-1"})
        |> render_change()

        extract(view)
        wait_for(view, "#invoice_issuer_name[value='GitHub, Inc.']")

        assert has_element?(view, "#invoice_number[value=MY-1]")
      end

      test "tells when the model could not read the invoice", %{view: view} do
        InvoiceExtractorStub.stub({:error, :invalid_response})

        upload_pdf(view, "gh.pdf", pdf_fixture())
        view |> form("#invoice-form", invoice: %{issuer_name: "Typed"}) |> render_change()
        extract(view)
        wait_for(view, "#invoice-form-extract-error")

        assert has_element?(view, "#invoice_issuer_name[value=Typed]")
        assert has_element?(view, "#invoice-form-extract:not([disabled])")
      end

      test "tells when the model found nothing", %{view: view} do
        InvoiceExtractorStub.stub({:ok, Map.new(found(), fn {field, _} -> {field, nil} end)})

        upload_pdf(view, "gh.pdf", pdf_fixture())
        extract(view)

        wait_for(view, "#invoice-form-extract-error")
      end

      test "tells when the provider fails", %{view: view} do
        InvoiceExtractorStub.stub({:error, :rate_limited})

        upload_pdf(view, "gh.pdf", pdf_fixture())
        extract(view)

        wait_for(view, "#invoice-form-extract-error")
        assert render(view) =~ "busy"
      end

      test "tells the model who the business of the user is, and never another's", %{
        view: view,
        scope: scope
      } do
        settings_fixture(
          scope,
          %{"business_name" => "My Own Ltd", "business_vat" => "EL111111111"},
          token: nil
        )

        settings_fixture(
          user_scope_fixture(),
          %{"business_name" => "Other Corp", "business_vat" => "EL222222222"},
          token: nil
        )

        InvoiceExtractorStub.stub({:ok, found()})

        upload_pdf(view, "gh.pdf", pdf_fixture())
        extract(view)
        wait_for(view, "#invoice_issuer_name[value='GitHub, Inc.']")

        assert_received {:extract_request, _pdf, prompt, _fields, _model}
        assert prompt =~ "My Own Ltd, VAT number EL111111111"
        refute prompt =~ "Other Corp"
        refute prompt =~ "EL222222222"
      end

      test "does not name a business when the user has not set theirs", %{
        view: view,
        scope: scope
      } do
        settings_fixture(user_scope_fixture(), %{"business_name" => "Other Corp"}, token: nil)
        assert IkeEmails.Settings.business(scope) == nil

        InvoiceExtractorStub.stub({:ok, found()})

        upload_pdf(view, "gh.pdf", pdf_fixture())
        extract(view)
        wait_for(view, "#invoice_issuer_name[value='GitHub, Inc.']")

        assert_received {:extract_request, _pdf, prompt, _fields, _model}
        refute prompt =~ "The business that keeps these invoices"
        refute prompt =~ "Other Corp"
      end

      test "forgets the result when the upload is cancelled meanwhile", %{view: view} do
        InvoiceExtractorStub.hold({:ok, found()})

        upload_pdf(view, "gh.pdf", pdf_fixture())
        extract(view)
        assert_receive {:held, task}
        ref = Process.monitor(task)

        view |> element("#invoice-form button[phx-click=cancel-upload]") |> render_click()

        assert_receive {:DOWN, ^ref, :process, ^task, _reason}
        refute has_element?(view, "#invoice-form-extract")
        refute has_element?(view, "#invoice_issuer_name[value='GitHub, Inc.']")
        refute has_element?(view, "#invoice-form-extract-error")
      end
    end
  end

  describe "on the attach panel" do
    test "tells the model what the bank shows", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      InvoiceExtractorStub.stub({:ok, found()})

      view = attach_panel(conn, transaction)
      upload_pdf(view, "gh.pdf", pdf_fixture())
      extract(view)
      wait_for(view, "#invoice_issuer_name[value='GitHub, Inc.']")

      assert_received {:extract_request, _pdf, prompt, _fields, _model}
      assert prompt =~ "amount 193,44, currency EUR, date 2026-10-12"
    end

    test "matches the invoice that was read to the transaction", %{conn: conn, scope: scope} do
      transaction = transaction_fixture(scope)
      InvoiceExtractorStub.stub({:ok, found()})

      view = attach_panel(conn, transaction)
      upload_pdf(view, "gh.pdf", pdf_fixture())
      extract(view)
      wait_for(view, "#invoice_issuer_name[value='GitHub, Inc.']")
      view |> form("#invoice-form") |> render_submit()

      assert_patch(view, ~p"/?month=2026-10")
      assert [invoice] = Banking.get_transaction!(scope, transaction.id).invoices
      assert invoice.issuer_name == "GitHub, Inc."
    end

    test "forgets the result when another transaction is opened meanwhile", %{
      conn: conn,
      scope: scope
    } do
      first = transaction_fixture(scope)
      second = transaction_fixture(scope)
      InvoiceExtractorStub.hold({:ok, found()})

      view = attach_panel(conn, first)
      upload_pdf(view, "gh.pdf", pdf_fixture())
      extract(view)
      assert_receive {:held, task}
      ref = Process.monitor(task)

      render_patch(view, ~p"/transactions/#{second.id}/invoice?month=2026-10")

      assert_receive {:DOWN, ^ref, :process, ^task, _reason}
      refute has_element?(view, "#invoice_issuer_name[value='GitHub, Inc.']")
      refute has_element?(view, "#invoice-form-extract-error")
    end
  end

  describe "without a model" do
    setup do
      settings = Application.fetch_env!(:ike_emails, InvoiceExtractor)
      Application.put_env(:ike_emails, InvoiceExtractor, Keyword.put(settings, :model, nil))
      on_exit(fn -> Application.put_env(:ike_emails, InvoiceExtractor, settings) end)
    end

    test "says how to set it up, and offers no button", %{conn: conn} do
      view = new_invoice_page(conn)
      upload_pdf(view, "gh.pdf", pdf_fixture())

      refute has_element?(view, "#invoice-form-extract")
      assert has_element?(view, "#invoice-form-extract-hint", "AI_MODEL")
    end
  end
end
