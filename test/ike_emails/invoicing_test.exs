defmodule IkeEmails.InvoicingTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmails.Invoicing
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Storage.InMemory

  describe "create_invoice/4" do
    test "stores the invoice and its PDF" do
      pdf = pdf_fixture()

      assert {:ok, invoice} = Invoicing.create_invoice(invoice_attrs(), pdf, "elorus.pdf")

      assert invoice.amount_cents == 19_344
      assert invoice.currency == "EUR"
      assert invoice.date == ~D[2026-10-09]
      assert invoice.issuer_vat == "EL094019245"
      assert invoice.file_name == "elorus.pdf"
      assert invoice.file_size == byte_size(pdf)
      assert invoice.file_key == "invoices/#{invoice.file_sha256}.pdf"
      assert invoice.transactions == []
      assert {^pdf, "application/pdf"} = InMemory.get(invoice.file_key)
    end

    test "links the invoice to the given transactions" do
      [first, second] = [transaction_fixture(), transaction_fixture()]

      invoice = invoice_fixture(%{}, transaction_ids: [first.id, second.id])

      assert Enum.sort(Enum.map(invoice.transactions, & &1.id)) == [first.id, second.id]
      assert [%{id: id}] = Banking.get_transaction!(first.id).invoices
      assert id == invoice.id
    end

    test "links the invoice to a transaction that was marked as needing none" do
      transaction = transaction_fixture()
      {:ok, _} = Banking.mark_no_invoice(transaction, "accountant fee")

      invoice_fixture(%{}, transaction_ids: [transaction.id])

      transaction = Banking.get_transaction!(transaction.id)
      assert transaction.no_invoice == false
      assert transaction.no_invoice_note == nil
      assert Banking.status(transaction) == :invoiced
    end

    test "defaults the currency to EUR and cleans it up" do
      attrs = invoice_attrs() |> Map.delete("currency")
      assert {:ok, %{currency: "EUR"}} = Invoicing.create_invoice(attrs, pdf_fixture(), "a.pdf")

      attrs = invoice_attrs(%{"currency" => " usd "})
      assert {:ok, %{currency: "USD"}} = Invoicing.create_invoice(attrs, pdf_fixture(), "b.pdf")
    end

    test "the issuer VAT is optional" do
      attrs = invoice_attrs(%{"issuer_vat" => ""})

      assert {:ok, %{issuer_vat: nil}} = Invoicing.create_invoice(attrs, pdf_fixture(), "a.pdf")
    end

    test "rejects a file that is not a PDF, whatever its name" do
      assert {:error, :not_a_pdf} =
               Invoicing.create_invoice(invoice_attrs(), "just text", "invoice.pdf")

      assert Repo.aggregate(Invoice, :count) == 0
    end

    test "rejects a PDF that is too large" do
      big = "%PDF-" <> :binary.copy("0", Invoicing.max_pdf_bytes())

      assert {:error, :too_large} = Invoicing.create_invoice(invoice_attrs(), big, "big.pdf")
    end

    test "returns a changeset and stores nothing for invalid attributes" do
      pdf = pdf_fixture()
      attrs = invoice_attrs(%{"amount_input" => "lots", "issuer_name" => "", "date" => ""})

      assert {:error, changeset} = Invoicing.create_invoice(attrs, pdf, "a.pdf")

      assert %{
               amount_input: ["is invalid"],
               issuer_name: ["can't be blank"],
               date: ["can't be blank"]
             } = errors_on(changeset)

      hash = :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)
      refute InMemory.exists?("invoices/#{hash}.pdf")
    end

    test "rejects an amount the database cannot hold, before storing the PDF" do
      pdf = pdf_fixture()
      attrs = invoice_attrs(%{"amount_input" => "30000000"})

      assert {:error, changeset} = Invoicing.create_invoice(attrs, pdf, "a.pdf")
      assert %{amount_input: ["is too large"]} = errors_on(changeset)

      hash = :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)
      refute InMemory.exists?("invoices/#{hash}.pdf")

      attrs = invoice_attrs(%{"amount_input" => "21474836,47"})
      assert {:ok, %{amount_cents: 2_147_483_647}} = Invoicing.create_invoice(attrs, pdf, "a.pdf")
    end

    test "counts the length of text like the database does" do
      # 300 combining accents make a single grapheme but 301 characters for Postgres
      name = "e" <> String.duplicate("\u0301", 300)
      attrs = invoice_attrs(%{"issuer_name" => name})

      assert {:error, changeset} = Invoicing.create_invoice(attrs, pdf_fixture(), "a.pdf")
      assert %{issuer_name: [_]} = errors_on(changeset)
    end

    test "rejects an amount of zero" do
      attrs = invoice_attrs(%{"amount_input" => "0,00"})

      assert {:error, changeset} = Invoicing.create_invoice(attrs, pdf_fixture(), "a.pdf")
      assert %{amount_input: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "returns the existing invoice when the same PDF is uploaded again" do
      pdf = pdf_fixture()
      {:ok, invoice} = Invoicing.create_invoice(invoice_attrs(), pdf, "a.pdf")

      assert {:error, {:duplicate, existing}} =
               Invoicing.create_invoice(invoice_attrs(%{"issuer_name" => "Other"}), pdf, "b.pdf")

      assert existing.id == invoice.id
      assert Repo.aggregate(Invoice, :count) == 1
    end

    test "removes the stored PDF when the invoice cannot be saved" do
      pdf = pdf_fixture()

      assert {:error, :unknown_transaction} =
               Invoicing.create_invoice(invoice_attrs(), pdf, "a.pdf", transaction_ids: [-1])

      hash = :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)
      refute InMemory.exists?("invoices/#{hash}.pdf")
      assert Repo.aggregate(Invoice, :count) == 0
    end
  end

  describe "update_invoice/2" do
    test "updates what is typed in and keeps the PDF" do
      invoice = invoice_fixture()

      assert {:ok, updated} =
               Invoicing.update_invoice(invoice, %{"amount_input" => "200", "number" => "X-1"})

      assert updated.amount_cents == 20_000
      assert updated.number == "X-1"
      assert updated.file_key == invoice.file_key
    end

    test "keeps the amount when it is not changed" do
      invoice = invoice_fixture()

      assert {:ok, updated} = Invoicing.update_invoice(invoice, %{"notes" => "paid by card"})
      assert updated.amount_cents == 19_344
    end

    test "rejects a blank amount" do
      invoice = invoice_fixture()

      assert {:error, changeset} = Invoicing.update_invoice(invoice, %{"amount_input" => ""})
      assert %{amount_input: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "attach/2 and detach/2" do
    test "match an invoice to a transaction, and undo it" do
      transaction = transaction_fixture()
      invoice = invoice_fixture()

      assert :ok = Invoicing.attach(invoice, transaction)
      assert [%{id: id}] = Banking.get_transaction!(transaction.id).invoices
      assert id == invoice.id

      assert :ok = Invoicing.detach(invoice, transaction)
      assert Banking.get_transaction!(transaction.id).invoices == []
    end

    test "attaching twice leaves one match" do
      transaction = transaction_fixture()
      invoice = invoice_fixture()

      assert :ok = Invoicing.attach(invoice, transaction)
      assert :ok = Invoicing.attach(invoice, transaction)

      assert length(Banking.get_transaction!(transaction.id).invoices) == 1
    end

    test "one invoice can pay for several transactions and a transaction can have several invoices" do
      [t1, t2] = [transaction_fixture(), transaction_fixture()]
      [i1, i2] = [invoice_fixture(), invoice_fixture()]

      for invoice <- [i1, i2], transaction <- [t1, t2] do
        :ok = Invoicing.attach(invoice, transaction)
      end

      assert length(Banking.get_transaction!(t1.id).invoices) == 2
      assert length(Invoicing.get_invoice!(i2.id).transactions) == 2
    end

    test "attaching clears the mark that the transaction needs no invoice" do
      transaction = transaction_fixture()
      {:ok, _} = Banking.mark_no_invoice(transaction, "tax")

      :ok = Invoicing.attach(invoice_fixture(), transaction)

      transaction = Banking.get_transaction!(transaction.id)
      assert transaction.no_invoice == false
      assert transaction.no_invoice_note == nil
    end

    test "attaching clears a mark that has no reason too" do
      transaction = transaction_fixture()
      {:ok, _} = Banking.mark_no_invoice(transaction)

      :ok = Invoicing.attach(invoice_fixture(), transaction)

      assert Banking.get_transaction!(transaction.id).no_invoice == false
    end

    test "detaching an invoice that is not attached is fine" do
      assert :ok = Invoicing.detach(invoice_fixture(), transaction_fixture())
    end
  end

  describe "delete_invoice/1" do
    test "removes the invoice and its PDF, and keeps the transaction" do
      transaction = transaction_fixture()
      invoice = invoice_fixture(%{}, transaction_ids: [transaction.id])

      assert {:ok, _} = Invoicing.delete_invoice(invoice)

      refute InMemory.exists?(invoice.file_key)
      assert_raise Ecto.NoResultsError, fn -> Invoicing.get_invoice!(invoice.id) end
      assert Banking.get_transaction!(transaction.id).invoices == []
    end
  end

  describe "the receiver" do
    test "is optional, and its VAT number is normalized like the issuer's" do
      assert {:ok, expense} = Invoicing.create_invoice(invoice_attrs(), pdf_fixture(), "a.pdf")
      assert {expense.receiver_name, expense.receiver_vat} == {nil, nil}

      attrs = invoice_attrs(%{"receiver_name" => "Acme Inc.", "receiver_vat" => "el 123.456-789"})
      assert {:ok, issued} = Invoicing.create_invoice(attrs, pdf_fixture(), "b.pdf")
      assert {issued.receiver_name, issued.receiver_vat} == {"Acme Inc.", "EL123456789"}
    end

    test "has limits on its length" do
      attrs =
        invoice_attrs(%{
          "receiver_name" => String.duplicate("é", 256),
          "receiver_vat" => String.duplicate("1", 33)
        })

      assert {:error, changeset} = Invoicing.create_invoice(attrs, pdf_fixture(), "a.pdf")

      assert %{
               receiver_name: ["should be at most 255 character(s)"],
               receiver_vat: ["should be at most 32 character(s)"]
             } = errors_on(changeset)
    end

    test "can be edited, but the Elorus id cannot" do
      invoice = invoice_fixture()

      assert {:ok, updated} =
               Invoicing.update_invoice(invoice, %{
                 "receiver_name" => "Acme",
                 "elorus_id" => "hacked"
               })

      assert updated.receiver_name == "Acme"
      assert updated.elorus_id == nil
    end
  end

  describe "list_invoices/1" do
    test "lists the newest first, with their transactions" do
      transaction = transaction_fixture()
      older = invoice_fixture(%{"date" => "2026-09-01"})
      newer = invoice_fixture(%{"date" => "2026-10-01"}, transaction_ids: [transaction.id])

      assert [first, second] = Invoicing.list_invoices()
      assert {first.id, second.id} == {newer.id, older.id}
      assert [%{id: id}] = first.transactions
      assert id == transaction.id
      assert second.transactions == []
    end

    test "searches the issuer name and the number, case insensitively" do
      github = invoice_fixture(%{"issuer_name" => "GitHub, Inc.", "number" => "GH-1"})
      _other = invoice_fixture(%{"issuer_name" => "Linode", "number" => "LN-77"})

      assert [%{id: id}] = Invoicing.list_invoices(search: "github")
      assert id == github.id
      assert [%{issuer_name: "Linode"}] = Invoicing.list_invoices(search: "ln-7")
      assert length(Invoicing.list_invoices(search: "  ")) == 2
    end

    test "searches the receiver name too" do
      issued = invoice_fixture(%{"issuer_name" => "Me", "receiver_name" => "Acme Inc."})
      _expense = invoice_fixture(%{"issuer_name" => "Linode"})

      assert [%{id: id}] = Invoicing.list_invoices(search: "acme")
      assert id == issued.id
    end

    test "does not treat wildcards in the search as wildcards" do
      invoice_fixture(%{"issuer_name" => "Linode"})

      assert Invoicing.list_invoices(search: "%") == []
      assert Invoicing.list_invoices(search: "_inode") == []
    end
  end

  describe "suggest_invoices/2" do
    test "puts the invoice of the same amount first, then the unmatched ones, then the closest in date" do
      transaction = transaction_fixture(%{"amount" => "-193.44", "date" => "2026-10-12"})
      other = transaction_fixture()

      matched_close =
        invoice_fixture(%{"amount_input" => "10", "date" => "2026-10-11"},
          transaction_ids: [other.id]
        )

      unmatched_far = invoice_fixture(%{"amount_input" => "20", "date" => "2026-08-01"})
      unmatched_close = invoice_fixture(%{"amount_input" => "30", "date" => "2026-10-10"})

      exact =
        invoice_fixture(%{"amount_input" => "193,44", "date" => "2026-07-01"},
          transaction_ids: [other.id]
        )

      ids = transaction |> Invoicing.suggest_invoices() |> Enum.map(& &1.id)

      assert ids == [exact.id, unmatched_close.id, unmatched_far.id, matched_close.id]
    end

    test "leaves out the invoices already on the transaction" do
      transaction = transaction_fixture()
      attached = invoice_fixture(%{}, transaction_ids: [transaction.id])
      free = invoice_fixture()

      ids = transaction |> Invoicing.suggest_invoices() |> Enum.map(& &1.id)

      assert ids == [free.id]
      refute attached.id in ids
    end

    test "narrows by issuer name" do
      transaction = transaction_fixture()
      invoice_fixture(%{"issuer_name" => "Linode"})
      github = invoice_fixture(%{"issuer_name" => "GitHub"})

      assert [%{id: id}] = Invoicing.suggest_invoices(transaction, "git")
      assert id == github.id
    end
  end

  test "pdf_url/1 is a temporary URL of the stored PDF" do
    invoice = invoice_fixture()

    assert Invoicing.pdf_url(invoice) =~ invoice.file_key
  end

  describe "new_invoice_for/1" do
    test "suggests the amount of a transaction in euros" do
      transaction = transaction_fixture(%{"amount" => "-1234.50", "value_date" => "2026-10-09"})

      assert %Invoice{amount_input: "1.234,50", currency: "EUR", date: ~D[2026-10-09]} =
               Invoicing.new_invoice_for(transaction)
    end

    test "suggests the amount and currency a charge was converted from" do
      transaction =
        transaction_fixture(%{"amount" => "-18.01", "conversion_details" => "20,00 USD"})

      assert %Invoice{amount_input: "20,00", currency: "USD"} =
               Invoicing.new_invoice_for(transaction)
    end

    test "ignores conversion details it cannot read" do
      transaction =
        transaction_fixture(%{"amount" => "-18.01", "conversion_details" => "see statement"})

      assert %Invoice{amount_input: "18,01", currency: "EUR"} =
               Invoicing.new_invoice_for(transaction)
    end
  end
end
