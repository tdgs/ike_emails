defmodule IkeEmails.OwnershipTest do
  use IkeEmails.DataCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmails.Invoicing
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Storage.InMemory

  @bank_line %{
    "date" => "2026-10-19",
    "value_date" => "2026-10-17",
    "description" => "ANTHROPIC* CLAUDE SU",
    "branch" => "99",
    "transaction_id" => "202610190993537650",
    "amount" => "-90.00"
  }

  setup do
    %{scope_a: user_scope_fixture(), scope_b: user_scope_fixture()}
  end

  describe "transactions" do
    test "are listed for their user only", %{scope_a: a, scope_b: b} do
      mine = transaction_fixture(a, %{"date" => "2026-10-12"})
      theirs = transaction_fixture(b, %{"date" => "2026-10-12"})
      other_month = transaction_fixture(b, %{"date" => "2026-03-02"})

      assert [%{id: id}] = Banking.list_transactions(a)
      assert id == mine.id
      assert [%{id: id}] = Banking.list_transactions_for_month(a, 2026, 10)
      assert id == mine.id

      assert Enum.sort(Enum.map(Banking.list_transactions(b), & &1.id)) ==
               Enum.sort([theirs.id, other_month.id])
    end

    test "do not show up in the months of another user", %{scope_a: a, scope_b: b} do
      transaction_fixture(b, %{"date" => "2026-03-02"})
      transaction_fixture(a, %{"date" => "2026-10-12"})

      assert Banking.months_with_transactions(a) == [~D[2026-10-01]]
      assert Banking.months_with_transactions(b) == [~D[2026-03-01]]
      assert Banking.list_transactions_for_month(a, 2026, 3) == []
    end

    test "cannot be fetched by another user", %{scope_a: a, scope_b: b} do
      transaction = transaction_fixture(a)

      assert Banking.get_transaction!(a, transaction.id).id == transaction.id

      assert_raise Ecto.NoResultsError, fn -> Banking.get_transaction!(b, transaction.id) end
    end

    test "can be the same bank line for two users", %{scope_a: a, scope_b: b} do
      assert {:ok, :created, mine} = Banking.create_transaction(a, @bank_line)
      assert {:ok, :created, theirs} = Banking.create_transaction(b, @bank_line)

      assert mine.id != theirs.id
      assert {mine.user_id, theirs.user_id} == {a.user.id, b.user.id}
    end

    test "pushed again by the same user are the existing ones", %{scope_a: a, scope_b: b} do
      {:ok, :created, mine} = Banking.create_transaction(a, @bank_line)
      {:ok, :created, theirs} = Banking.create_transaction(b, @bank_line)

      assert {:ok, :existing, existing} = Banking.create_transaction(a, @bank_line)
      assert existing.id == mine.id
      assert {:ok, :existing, existing} = Banking.create_transaction(b, @bank_line)
      assert existing.id == theirs.id
    end

    test "cannot be given to a user by the pushed fields", %{scope_a: a, scope_b: b} do
      attrs = Map.put(@bank_line, "user_id", b.user.id)

      assert {:ok, :created, transaction} = Banking.create_transaction(a, attrs)
      assert transaction.user_id == a.user.id
      assert Banking.list_transactions(b) == []
    end

    test "cannot be marked or cleared by another user", %{scope_a: a, scope_b: b} do
      transaction = transaction_fixture(a)
      {:ok, marked} = Banking.mark_no_invoice(a, transaction, "tax")

      assert_raise ArgumentError, fn -> Banking.mark_no_invoice(b, transaction, "mine") end
      assert_raise ArgumentError, fn -> Banking.clear_no_invoice(b, marked) end

      assert %{no_invoice: true, no_invoice_note: "tax"} =
               Banking.get_transaction!(a, transaction.id)
    end

    test "cannot be marked by another user even when they have invoices", %{
      scope_a: a,
      scope_b: b
    } do
      transaction = transaction_fixture(a)
      :ok = Invoicing.attach(a, invoice_fixture(a), transaction)
      transaction = Banking.get_transaction!(a, transaction.id)

      assert_raise ArgumentError, fn -> Banking.mark_no_invoice(b, transaction, "tax") end
    end
  end

  describe "invoices" do
    test "are listed for their user only", %{scope_a: a, scope_b: b} do
      mine = invoice_fixture(a)
      _theirs = invoice_fixture(b)

      assert [%{id: id}] = Invoicing.list_invoices(a)
      assert id == mine.id
      assert [%{id: id}] = Invoicing.list_invoices(a, search: "elorus")
      assert id == mine.id
      assert Invoicing.list_invoices(a, search: "nobody") == []
    end

    test "cannot be fetched by another user", %{scope_a: a, scope_b: b} do
      invoice = invoice_fixture(a)

      assert Invoicing.get_invoice!(a, invoice.id).id == invoice.id
      assert_raise Ecto.NoResultsError, fn -> Invoicing.get_invoice!(b, invoice.id) end
    end

    test "are only suggested to the transactions of their user", %{scope_a: a, scope_b: b} do
      transaction = transaction_fixture(a)
      mine = invoice_fixture(a)
      _theirs = invoice_fixture(b)

      assert [%{id: id}] = Invoicing.suggest_invoices(a, transaction)
      assert id == mine.id
      assert_raise ArgumentError, fn -> Invoicing.suggest_invoices(b, transaction) end
    end

    test "can be the same PDF for two users, each with their own object", %{
      scope_a: a,
      scope_b: b
    } do
      pdf = pdf_fixture()

      assert {:ok, mine} = Invoicing.create_invoice(a, invoice_attrs(), pdf, "a.pdf")
      assert {:ok, theirs} = Invoicing.create_invoice(b, invoice_attrs(), pdf, "b.pdf")

      assert mine.file_sha256 == theirs.file_sha256
      assert mine.file_key != theirs.file_key
      assert mine.file_key == "invoices/#{a.user.id}/#{mine.file_sha256}.pdf"
      assert theirs.file_key == "invoices/#{b.user.id}/#{theirs.file_sha256}.pdf"
      assert {^pdf, "application/pdf"} = InMemory.get(mine.file_key)
      assert {^pdf, "application/pdf"} = InMemory.get(theirs.file_key)
    end

    test "are told apart as duplicates per user", %{scope_a: a, scope_b: b} do
      pdf = pdf_fixture()
      {:ok, mine} = Invoicing.create_invoice(a, invoice_attrs(), pdf, "a.pdf")
      {:ok, theirs} = Invoicing.create_invoice(b, invoice_attrs(), pdf, "b.pdf")

      assert {:error, {:duplicate, existing}} =
               Invoicing.create_invoice(a, invoice_attrs(), pdf, "again.pdf")

      assert existing.id == mine.id

      assert {:error, {:duplicate, existing}} =
               Invoicing.create_invoice(b, invoice_attrs(), pdf, "again.pdf")

      assert existing.id == theirs.id
      assert Repo.aggregate(Invoice, :count) == 2
    end

    test "deleting one leaves the PDF of the same file of another user", %{
      scope_a: a,
      scope_b: b
    } do
      pdf = pdf_fixture()
      {:ok, mine} = Invoicing.create_invoice(a, invoice_attrs(), pdf, "a.pdf")
      {:ok, theirs} = Invoicing.create_invoice(b, invoice_attrs(), pdf, "b.pdf")

      assert {:ok, _} = Invoicing.delete_invoice(a, mine)

      refute InMemory.exists?(mine.file_key)
      assert {^pdf, "application/pdf"} = InMemory.get(theirs.file_key)
      assert Invoicing.get_invoice!(b, theirs.id).id == theirs.id
    end

    test "a failed creation leaves the PDF of the same file of another user", %{
      scope_a: a,
      scope_b: b
    } do
      pdf = pdf_fixture()
      {:ok, theirs} = Invoicing.create_invoice(b, invoice_attrs(), pdf, "b.pdf")

      assert {:error, :unknown_transaction} =
               Invoicing.create_invoice(a, invoice_attrs(), pdf, "a.pdf", transaction_ids: [-1])

      assert {^pdf, "application/pdf"} = InMemory.get(theirs.file_key)
    end

    test "cannot be linked to the transactions of another user", %{scope_a: a, scope_b: b} do
      theirs = transaction_fixture(b)
      pdf = pdf_fixture()

      assert {:error, :unknown_transaction} =
               Invoicing.create_invoice(a, invoice_attrs(), pdf, "a.pdf",
                 transaction_ids: [theirs.id]
               )

      assert Repo.aggregate(Invoice, :count) == 0
      refute InMemory.exists?("invoices/#{a.user.id}/#{sha256(pdf)}.pdf")
      assert Banking.get_transaction!(b, theirs.id).invoices == []
    end

    test "cannot be linked to a mix of own and foreign transactions", %{scope_a: a, scope_b: b} do
      mine = transaction_fixture(a)
      theirs = transaction_fixture(b)

      assert {:error, :unknown_transaction} =
               Invoicing.create_invoice(a, invoice_attrs(), pdf_fixture(), "a.pdf",
                 transaction_ids: [mine.id, theirs.id]
               )

      assert Banking.get_transaction!(a, mine.id).invoices == []
    end

    test "cannot be attached or detached by another user", %{scope_a: a, scope_b: b} do
      mine = invoice_fixture(a)
      transaction = transaction_fixture(a)
      other_transaction = transaction_fixture(b)
      other_invoice = invoice_fixture(b)

      assert_raise ArgumentError, fn -> Invoicing.attach(b, mine, transaction) end
      assert_raise ArgumentError, fn -> Invoicing.attach(a, mine, other_transaction) end
      assert_raise ArgumentError, fn -> Invoicing.attach(a, other_invoice, transaction) end

      :ok = Invoicing.attach(a, mine, transaction)
      assert_raise ArgumentError, fn -> Invoicing.detach(b, mine, transaction) end
      assert_raise ArgumentError, fn -> Invoicing.detach(a, other_invoice, transaction) end

      assert [%{id: id}] = Banking.get_transaction!(a, transaction.id).invoices
      assert id == mine.id
    end

    test "cannot be updated or deleted by another user", %{scope_a: a, scope_b: b} do
      invoice = invoice_fixture(a)

      assert_raise ArgumentError, fn ->
        Invoicing.update_invoice(b, invoice, %{"issuer_name" => "Hacked"})
      end

      assert_raise ArgumentError, fn -> Invoicing.delete_invoice(b, invoice) end

      assert %{issuer_name: "Elorus"} = Invoicing.get_invoice!(a, invoice.id)
      assert InMemory.exists?(invoice.file_key)
    end
  end

  describe "Elorus invoices" do
    test "can be imported by two users", %{scope_a: a, scope_b: b} do
      mine = invoice_fixture(a, %{}, elorus_id: "x")
      theirs = invoice_fixture(b, %{}, elorus_id: "x")

      assert mine.id != theirs.id
      assert mine.elorus_id == theirs.elorus_id
    end

    test "are told apart as imported per user", %{scope_a: a, scope_b: b} do
      invoice_fixture(a, %{}, elorus_id: "x")
      invoice_fixture(b, %{}, elorus_id: "y")

      assert Invoicing.imported_elorus_ids(a, ["x", "y", "z"]) == MapSet.new(["x"])
      assert Invoicing.imported_elorus_ids(b, ["x", "y", "z"]) == MapSet.new(["y"])
      assert Invoicing.imported_elorus_ids(a, []) == MapSet.new()
    end

    test "cannot be imported twice by the same user", %{scope_a: a} do
      invoice_fixture(a, %{}, elorus_id: "x")

      assert {:error, changeset} =
               Invoicing.create_invoice(a, invoice_attrs(), pdf_fixture(), "a.pdf",
                 elorus_id: "x"
               )

      assert %{elorus_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  defp sha256(pdf), do: :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)

  describe "proposals" do
    test "cannot be fetched, approved or rejected by another user", %{scope_a: a, scope_b: b} do
      transaction = transaction_fixture(a)

      {:ok, proposal} =
        IkeEmails.MonthClose.put_proposal(a, transaction, %{}, %{
          "kind" => "no_invoice",
          "rationale" => "It is a commission of the bank."
        })

      assert IkeEmails.MonthClose.get_proposal(b, proposal.id) == nil
      assert_raise ArgumentError, fn -> IkeEmails.MonthClose.approve(b, proposal) end
      assert_raise ArgumentError, fn -> IkeEmails.MonthClose.reject(b, proposal) end
      assert IkeEmails.MonthClose.get_proposal(a, proposal.id)
    end

    test "cannot be made for the transaction of another user", %{scope_a: a, scope_b: b} do
      transaction = transaction_fixture(a)

      assert_raise ArgumentError, fn ->
        IkeEmails.MonthClose.put_proposal(b, transaction, %{}, %{
          "kind" => "no_invoice",
          "rationale" => "It is a commission of the bank."
        })
      end
    end
  end
end
