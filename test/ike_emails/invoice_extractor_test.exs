defmodule IkeEmails.InvoiceExtractorTest do
  # Not async: the stub and the settings are global
  use ExUnit.Case, async: false

  import IkeEmails.Fixtures, only: [pdf_fixture: 0]
  import IkeEmails.InvoiceExtractorStub, only: [found: 0, found: 1]

  alias IkeEmails.InvoiceExtractor
  alias IkeEmails.InvoiceExtractorStub

  setup do
    settings = Application.fetch_env!(:ike_emails, InvoiceExtractor)
    on_exit(fn -> Application.put_env(:ike_emails, InvoiceExtractor, settings) end)

    %{settings: settings}
  end

  describe "extract/2" do
    test "returns the form params of what the model found" do
      InvoiceExtractorStub.stub({:ok, found()})

      assert {:ok, params} = InvoiceExtractor.extract(pdf_fixture())

      assert params == %{
               "amount_input" => "146,38",
               "currency" => "USD",
               "date" => "2026-10-01",
               "issuer_name" => "GitHub, Inc.",
               "issuer_vat" => "EU 372 041 333",
               "number" => "GH-1001"
             }
    end

    test "sends the PDF, the fields and the configured model to the client" do
      pdf = pdf_fixture()
      InvoiceExtractorStub.stub({:ok, found()})

      InvoiceExtractor.extract(pdf)

      assert_receive {:extract_request, ^pdf, _prompt, fields, "test:model"}

      assert Keyword.keys(fields) ==
               ~w(amount currency date issuer_name issuer_vat number receiver_name receiver_vat)a
    end

    test "tells the model who the business is, and the hints from the bank" do
      InvoiceExtractorStub.stub({:ok, found()})

      InvoiceExtractor.extract(pdf_fixture(),
        business: %{name: "Test Business", vat: "EL099999999"},
        hints: %{amount_input: "146,38", currency: "USD", date: ~D[2026-10-01]}
      )

      assert_receive {:extract_request, _pdf, prompt, _fields, _model}
      assert prompt =~ "Test Business, VAT number EL099999999"
      assert prompt =~ "amount 146,38, currency USD, date 2026-10-01"
    end

    test "tells the model the name of a business that has no VAT number" do
      InvoiceExtractorStub.stub({:ok, found()})

      InvoiceExtractor.extract(pdf_fixture(), business: %{name: "Me", vat: nil})

      assert_receive {:extract_request, _pdf, prompt, _fields, _model}
      assert prompt =~ "The business that keeps these invoices is Me. When it is the issuer"
      refute prompt =~ "VAT number"
    end

    for business <- [nil, %{name: nil, vat: "EL099999999"}, %{name: "", vat: nil}] do
      test "does not name a business without a name (#{inspect(business)})" do
        InvoiceExtractorStub.stub({:ok, found()})

        InvoiceExtractor.extract(pdf_fixture(), business: unquote(Macro.escape(business)))

        assert_receive {:extract_request, _pdf, prompt, _fields, _model}
        assert prompt =~ "Leave the receiver null unless the invoice was clearly issued"
        refute prompt =~ "The business that keeps these invoices"
        refute prompt =~ "EL099999999"
      end
    end

    test "does not name a business when none is given" do
      InvoiceExtractorStub.stub({:ok, found()})

      InvoiceExtractor.extract(pdf_fixture())

      assert_receive {:extract_request, _pdf, prompt, _fields, _model}
      refute prompt =~ "The business that keeps these invoices"
      refute prompt =~ "Test Business"
    end

    test "has no hints to tell when there are none" do
      InvoiceExtractorStub.stub({:ok, found()})

      InvoiceExtractor.extract(pdf_fixture())

      assert_receive {:extract_request, _pdf, prompt, _fields, _model}
      refute prompt =~ "The bank shows"
    end

    test "takes the receiver of an invoice that the business issued" do
      InvoiceExtractorStub.stub(
        {:ok,
         found(%{
           "issuer_name" => "Test Business",
           "receiver_name" => " Acme Inc. ",
           "receiver_vat" => "EL123456789"
         })}
      )

      assert {:ok, params} = InvoiceExtractor.extract(pdf_fixture())
      assert {params["receiver_name"], params["receiver_vat"]} == {"Acme Inc.", "EL123456789"}
    end

    test "leaves out what does not make sense" do
      InvoiceExtractorStub.stub(
        {:ok,
         found(%{
           "amount" => "about ten euros",
           "currency" => "dollars",
           "date" => "last Tuesday",
           "issuer_name" => "   ",
           "issuer_vat" => nil,
           "number" => 42
         })}
      )

      assert {:ok, params} = InvoiceExtractor.extract(pdf_fixture())
      assert params == %{}
    end

    test "leaves out an amount that is not positive, and an impossible date" do
      InvoiceExtractorStub.stub({:ok, found(%{"amount" => "0.00", "date" => "2026-02-31"})})

      assert {:ok, params} = InvoiceExtractor.extract(pdf_fixture())
      refute Map.has_key?(params, "amount_input")
      refute Map.has_key?(params, "date")
    end

    test "shows the amount the way it is typed in" do
      InvoiceExtractorStub.stub({:ok, found(%{"amount" => "1234.50"})})

      assert {:ok, %{"amount_input" => "1.234,50"}} = InvoiceExtractor.extract(pdf_fixture())
    end

    for reason <- [
          :missing_key,
          :unauthorized,
          :rate_limited,
          :timeout,
          :invalid_response,
          {:failed, "boom"}
        ] do
      test "passes on the error #{inspect(reason)} of the client" do
        InvoiceExtractorStub.stub({:error, unquote(Macro.escape(reason))})

        assert InvoiceExtractor.extract(pdf_fixture()) == {:error, unquote(Macro.escape(reason))}
      end
    end

    test "does nothing without a model", %{settings: settings} do
      Application.put_env(:ike_emails, InvoiceExtractor, Keyword.put(settings, :model, nil))
      InvoiceExtractorStub.stub({:ok, found()})

      refute InvoiceExtractor.configured?()
      assert InvoiceExtractor.extract(pdf_fixture()) == {:error, :not_configured}
      refute_received {:extract_request, _pdf, _prompt, _fields, _model}
    end
  end

  describe "configured?/0" do
    test "is true when a model is set" do
      assert InvoiceExtractor.configured?()
    end
  end
end
