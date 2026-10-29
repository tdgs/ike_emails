defmodule IkeEmails.BankingTest do
  use IkeEmails.DataCase, async: true

  alias IkeEmails.Banking

  @transfer %{
    "date" => "2026-07-07",
    "value_date" => "2026-07-07",
    "description" => "ΕΝΤΟΛΗ INSTANT TRANS",
    "branch" => "96",
    "transaction_id" => "202607070960257119",
    "amount" => "-14805.43",
    "conversion_details" => "",
    "sender_details" => "ΙΩΣΗΦΙΔΟΥ ΧΡΥΣΟΥΛΑ",
    "additional_information" => "ΜΕΡΙΣΜΑ 2025"
  }

  # The bank books the fee of a transfer under the transfer's transaction id.
  @fee %{
    "date" => "2026-07-07",
    "value_date" => "2026-07-07",
    "description" => "ΕΞΟΔΑ ΕΝΤΟΛΗΣ",
    "branch" => "96",
    "transaction_id" => "202607070960257119",
    "amount" => "-9.00"
  }

  describe "create_transaction/2" do
    setup :create_user_scope

    test "stores a transaction", %{scope: scope} do
      assert {:ok, :created, transaction} = Banking.create_transaction(scope, @transfer)

      assert transaction.description == "ΕΝΤΟΛΗ INSTANT TRANS"
      assert transaction.date == ~D[2026-07-07]
      assert Decimal.equal?(transaction.amount, Decimal.new("-14805.43"))
      assert [^transaction] = Banking.list_transactions(scope)
    end

    test "stores blank optional fields as nil", %{scope: scope} do
      assert {:ok, :created, transaction} = Banking.create_transaction(scope, @transfer)
      assert transaction.conversion_details == nil

      assert {:ok, :created, fee} = Banking.create_transaction(scope, @fee)
      assert fee.sender_details == nil
      assert fee.additional_information == nil
    end

    test "returns the stored transaction when it is pushed again", %{scope: scope} do
      assert {:ok, :created, transaction} = Banking.create_transaction(scope, @transfer)
      assert {:ok, :existing, existing} = Banking.create_transaction(scope, @transfer)

      assert existing.id == transaction.id
      assert length(Banking.list_transactions(scope)) == 1
    end

    test "treats the same amount in another notation as the same transaction", %{scope: scope} do
      assert {:ok, :created, transaction} = Banking.create_transaction(scope, @fee)

      assert {:ok, :existing, existing} =
               Banking.create_transaction(scope, %{@fee | "amount" => "-9"})

      assert existing.id == transaction.id
    end

    test "stores a transfer and its fee, which share a transaction id", %{scope: scope} do
      assert {:ok, :created, transfer} = Banking.create_transaction(scope, @transfer)
      assert {:ok, :created, fee} = Banking.create_transaction(scope, @fee)

      assert transfer.transaction_id == fee.transaction_id
      assert transfer.id != fee.id
      assert length(Banking.list_transactions(scope)) == 2
    end

    test "returns an error changeset for missing fields", %{scope: scope} do
      assert {:error, changeset} = Banking.create_transaction(scope, %{})

      assert %{
               date: ["can't be blank"],
               value_date: ["can't be blank"],
               description: ["can't be blank"],
               transaction_id: ["can't be blank"],
               amount: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "returns an error changeset for invalid values", %{scope: scope} do
      attrs = %{@transfer | "amount" => "lots", "date" => "yesterday"}

      assert {:error, changeset} = Banking.create_transaction(scope, attrs)
      assert %{amount: ["is invalid"], date: ["is invalid"]} = errors_on(changeset)
      assert Banking.list_transactions(scope) == []
    end
  end
end
