defmodule IkeEmails.InvoicingElorusTest do
  # Not async: some tests change the settings of the business
  use IkeEmails.DataCase, async: false

  import IkeEmails.ElorusStub
  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmails.Elorus
  alias IkeEmails.Invoicing
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Storage.InMemory

  defp from_api(attrs \\ %{}), do: attrs |> invoice_json() |> Elorus.Invoice.from_api()

  defp income(attrs \\ %{}), do: transaction_fixture(Map.merge(%{"amount" => "100.00"}, attrs))

  describe "search_elorus/2" do
    test "asks for the invoices of the month, drafts and void ones left out" do
      stub(invoices: [])

      assert {:ok, []} = Invoicing.search_elorus(income(), ~D[2026-10-17])

      assert %{
               "period_from" => "2026-10-01",
               "period_to" => "2026-10-31",
               "draft" => "0",
               "is_void" => "0",
               "page_size" => "250"
             } = last_query()
    end

    test "puts the invoices for the amount of the transaction first, the others keep their order" do
      stub(
        invoices: [
          invoice_json(%{"id" => "1", "total" => "30.00", "payable" => "30.00"}),
          invoice_json(%{"id" => "2", "total" => "100.00", "payable" => "100.00"}),
          invoice_json(%{"id" => "3", "total" => "50.00", "payable" => "50.00"}),
          invoice_json(%{"id" => "4", "total" => "100.00", "payable" => "100.00"})
        ]
      )

      assert {:ok, invoices} = Invoicing.search_elorus(income(), ~D[2026-10-01])
      assert Enum.map(invoices, & &1.id) == ["2", "4", "1", "3"]
    end

    test "matches what is payable too, which is less than the total when a tax is withheld" do
      stub(
        invoices: [
          invoice_json(%{"id" => "1", "total" => "30.00", "payable" => "30.00"}),
          invoice_json(%{"id" => "2", "total" => "125.00", "payable" => "100.00"})
        ]
      )

      assert {:ok, [%{id: "2"}, %{id: "1"}]} = Invoicing.search_elorus(income(), ~D[2026-10-01])
    end

    test "returns the error of Elorus" do
      stub(status: 401)

      assert Invoicing.search_elorus(income(), ~D[2026-10-01]) == {:error, :unauthorized}
    end
  end

  describe "elorus_match?/2" do
    test "compares the amount in cents" do
      transaction = income(%{"amount" => "123.45"})

      assert Invoicing.elorus_match?(from_api(%{"total" => "123.45"}), transaction)
      assert Invoicing.elorus_match?(from_api(%{"total" => "123.450"}), transaction)

      refute Invoicing.elorus_match?(
               from_api(%{"total" => "123.46", "payable" => "123.46"}),
               transaction
             )
    end

    test "needs the currency of the charge as well" do
      transaction = income(%{"amount" => "100.00"})

      refute Invoicing.elorus_match?(from_api(%{"currency_code" => "USD"}), transaction)
    end

    test "uses the foreign amount of the transaction when there is one" do
      transaction = income(%{"amount" => "18.40", "conversion_details" => "20,00 USD"})

      assert Invoicing.elorus_match?(
               from_api(%{"currency_code" => "USD", "total" => "20.00", "payable" => "20.00"}),
               transaction
             )

      refute Invoicing.elorus_match?(
               from_api(%{"currency_code" => "EUR", "total" => "18.40", "payable" => "18.40"}),
               transaction
             )
    end

    test "does not match an invoice without amounts" do
      refute Invoicing.elorus_match?(from_api(%{"total" => nil, "payable" => nil}), income())
    end
  end

  describe "imported_elorus_ids/1" do
    test "tells which Elorus invoices are stored" do
      stub()
      {:ok, _} = Invoicing.import_elorus_invoice(from_api(%{"id" => "7"}), income())

      assert Invoicing.imported_elorus_ids(["7", "8"]) == MapSet.new(["7"])
      assert Invoicing.imported_elorus_ids([]) == MapSet.new()
    end
  end

  describe "import_elorus_invoice/2" do
    test "stores the invoice and its PDF, and links the transaction" do
      stub(pdfs: %{"42" => pdf("42")})
      transaction = income()

      elorus_invoice =
        from_api(%{
          "id" => "42",
          "total" => "124.00",
          "payable" => "100.00",
          "date" => "2026-10-20"
        })

      assert {:ok, invoice} = Invoicing.import_elorus_invoice(elorus_invoice, transaction)

      assert %Invoice{
               amount_cents: 12_400,
               currency: "EUR",
               date: ~D[2026-10-20],
               issuer_name: "Test Business",
               issuer_vat: "EL099999999",
               receiver_name: "Acme Inc.",
               receiver_vat: "123451234",
               number: "A-1",
               notes: "Imported from Elorus",
               elorus_id: "42",
               file_name: "elorus-A-1.pdf"
             } = invoice

      assert {pdf("42"), "application/pdf"} == InMemory.get(invoice.file_key)
      assert [%{id: id}] = Banking.get_transaction!(transaction.id).invoices
      assert id == invoice.id
      assert Banking.status(Banking.get_transaction!(transaction.id)) == :invoiced

      assert request_paths() == ["/v1.2/invoices/42/pdf/"]
    end

    test "clears the mark that the transaction needs no invoice" do
      stub()
      transaction = income()
      {:ok, _} = Banking.mark_no_invoice(transaction, "to check")

      assert {:ok, _} = Invoicing.import_elorus_invoice(from_api(), transaction)

      assert %{no_invoice: false, no_invoice_note: nil} = Banking.get_transaction!(transaction.id)
    end

    test "attaches the invoice that was imported before, without downloading again" do
      stub()
      first = income()
      second = income()

      assert {:ok, invoice} = Invoicing.import_elorus_invoice(from_api(), first)
      assert request_paths() == ["/v1.2/invoices/1050000300010040/pdf/"]

      Req.Test.stub(Elorus, fn _conn -> flunk("the PDF must not be downloaded again") end)

      assert {:ok, again} = Invoicing.import_elorus_invoice(from_api(), first)
      assert {:ok, for_second} = Invoicing.import_elorus_invoice(from_api(), second)

      assert again.id == invoice.id
      assert for_second.id == invoice.id
      assert Repo.aggregate(Invoice, :count) == 1
      assert [_] = Banking.get_transaction!(first.id).invoices
      assert [_] = Banking.get_transaction!(second.id).invoices
    end

    test "attaches the invoice that holds the same PDF" do
      same = pdf("same")
      stub(pdfs: %{"1" => same, "2" => same})

      assert {:ok, first} = Invoicing.import_elorus_invoice(from_api(%{"id" => "1"}), income())
      transaction = income()

      assert {:ok, second} =
               Invoicing.import_elorus_invoice(from_api(%{"id" => "2"}), transaction)

      assert second.id == first.id
      assert Repo.aggregate(Invoice, :count) == 1
      assert [%{id: id}] = Banking.get_transaction!(transaction.id).invoices
      assert id == first.id
    end

    test "takes the invoice that holds the same PDF for the import, so that it is not downloaded again" do
      same = pdf("a")
      stub(pdfs: %{"a" => same})

      assert {:ok, uploaded} = Invoicing.create_invoice(invoice_attrs(), same, "by-hand.pdf")
      assert uploaded.elorus_id == nil

      transaction = income()

      assert {:ok, imported} =
               Invoicing.import_elorus_invoice(from_api(%{"id" => "a"}), transaction)

      assert imported.id == uploaded.id
      assert imported.elorus_id == "a"
      assert Invoicing.imported_elorus_ids(["a"]) == MapSet.new(["a"])
      assert [_] = Banking.get_transaction!(transaction.id).invoices
      # What was typed in by hand is left as it was
      assert imported.issuer_name == "Elorus"
      assert imported.receiver_name == nil

      Req.Test.stub(Elorus, fn _conn -> flunk("the PDF must not be downloaded again") end)

      assert {:ok, %{id: id}} =
               Invoicing.import_elorus_invoice(from_api(%{"id" => "a"}), income())

      assert id == uploaded.id
    end

    test "leaves alone an invoice that holds the PDF but belongs to another Elorus invoice" do
      same = pdf("same")
      stub(pdfs: %{"1" => same, "2" => same})

      assert {:ok, first} = Invoicing.import_elorus_invoice(from_api(%{"id" => "1"}), income())
      assert {:ok, second} = Invoicing.import_elorus_invoice(from_api(%{"id" => "2"}), income())

      assert second.id == first.id
      assert second.elorus_id == "1"
    end

    test "attaches the invoice that another import stored while this one downloaded" do
      # The other import commits between the check for a stored invoice and the insert
      Req.Test.stub(Elorus, fn conn ->
        {:ok, _} =
          Invoicing.create_invoice(invoice_attrs(), pdf("other bytes"), "other.pdf",
            elorus_id: "x"
          )

        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_resp(200, pdf("x"))
      end)

      transaction = income()

      assert {:ok, invoice} =
               Invoicing.import_elorus_invoice(from_api(%{"id" => "x"}), transaction)

      assert invoice.elorus_id == "x"
      assert Repo.aggregate(Invoice, :count) == 1
      assert [%{id: id}] = Banking.get_transaction!(transaction.id).invoices
      assert id == invoice.id
    end

    test "stores nothing when the PDF cannot be downloaded" do
      stub(status: 404)
      transaction = income()

      assert Invoicing.import_elorus_invoice(from_api(), transaction) == {:error, :not_found}

      assert Repo.aggregate(Invoice, :count) == 0
      assert Banking.get_transaction!(transaction.id).invoices == []
    end

    test "refuses an answer that is not a PDF" do
      Req.Test.stub(Elorus, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>login</html>") end)

      assert Invoicing.import_elorus_invoice(from_api(), income()) ==
               {:error, :invalid_response}

      assert Repo.aggregate(Invoice, :count) == 0
    end

    test "needs the name of the business, and downloads nothing without it" do
      original = Application.fetch_env!(:ike_emails, :business)
      on_exit(fn -> Application.put_env(:ike_emails, :business, original) end)
      Req.Test.stub(Elorus, fn _conn -> flunk("nothing must be downloaded") end)

      for settings <- [[], [name: nil], [name: "  "]] do
        Application.put_env(:ike_emails, :business, settings)

        assert Invoicing.import_elorus_invoice(from_api(), income()) ==
                 {:error, :business_not_configured}
      end
    end

    test "works with a business that has no VAT number" do
      original = Application.fetch_env!(:ike_emails, :business)
      on_exit(fn -> Application.put_env(:ike_emails, :business, original) end)
      Application.put_env(:ike_emails, :business, name: "Me", vat: nil)
      stub()

      assert {:ok, %Invoice{issuer_name: "Me", issuer_vat: nil}} =
               Invoicing.import_elorus_invoice(from_api(), income())
    end

    test "checks the invoice before it downloads the PDF" do
      Req.Test.stub(Elorus, fn _conn -> flunk("nothing must be downloaded") end)

      assert Invoicing.import_elorus_invoice(from_api(%{"total" => nil}), income()) ==
               {:error, :invalid_elorus_invoice}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Invoicing.import_elorus_invoice(from_api(%{"total" => "99999999999.00"}), income())

      assert %{amount_input: ["is too large"]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{}} =
               Invoicing.import_elorus_invoice(
                 from_api(%{"client_display_name" => String.duplicate("a", 300)}),
                 income()
               )
    end

    test "names the file safely" do
      stub()

      assert {:ok, invoice} =
               Invoicing.import_elorus_invoice(
                 from_api(%{"sequence_flat" => "../Τ/", "number" => "1 2"}),
                 income()
               )

      assert invoice.file_name == "elorus-..___1_2.pdf"
    end

    test "returns the error of Elorus" do
      stub(status: 429)

      assert Invoicing.import_elorus_invoice(from_api(), income()) ==
               {:error, {:rate_limited, nil}}
    end
  end
end
