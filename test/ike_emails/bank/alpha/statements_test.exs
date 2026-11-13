defmodule IkeEmails.Bank.Alpha.StatementsTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Statement
  alias IkeEmails.Bank.Alpha.Statements

  # Greek capital Chi (a debit) and Greek capital Pi (a credit), as the bank sends them
  @chi "\u{03A7}"
  @pi "\u{03A0}"

  defp line(fields) do
    Map.merge(
      %{
        "EntryDate" => "19/10/2026",
        "Valeur" => "17/10/2026",
        "Reason" => "A",
        "Branch" => "99",
        "TransactionUN" => "1",
        "Amount" => 1,
        "AmountSign" => @pi
      },
      fields
    )
  end

  defp body(lines, rest \\ %{}) do
    Jason.encode!(Map.put(rest, "Statements", lines))
  end

  defp amounts(%{statements: statements}) do
    Enum.map(statements, &Decimal.to_string(&1.amount, :normal))
  end

  describe "parse/1" do
    test "reads the lines in the order the bank gave them, a debit negative and a credit positive" do
      body = """
      {"Statements": [
        {"EntryDate": "19/10/2026", "Valeur": "17/10/2026", "Reason": "A", "Branch": "99", "TransactionUN": "1", "Amount": 90, "AmountSign": "#{@chi}"},
        {"EntryDate": "5/10/2026", "Valeur": "2/10/2026", "Reason": "B", "Branch": "99", "TransactionUN": "2", "Amount": 126.51, "AmountSign": "#{@pi}"}
      ]}
      """

      assert {:ok, %{statements: [first, second]}} = Statements.parse(body)

      assert %Statement{
               entry_date: "19/10/2026",
               value_date: "17/10/2026",
               reason: "A",
               branch: "99",
               transaction_id: "1",
               detail: nil
             } = first

      assert Decimal.equal?(first.amount, Decimal.new("-90"))

      assert %Statement{
               entry_date: "5/10/2026",
               value_date: "2/10/2026",
               reason: "B",
               transaction_id: "2",
               detail: nil
             } = second

      assert Decimal.equal?(second.amount, Decimal.new("126.51"))
    end

    test "takes the Latin X as a debit and the Latin P as a credit" do
      lines = [
        line(%{"Amount" => 5, "AmountSign" => "X"}),
        line(%{"Amount" => 6, "AmountSign" => "P"})
      ]

      assert {:ok, parsed} = Statements.parse(body(lines))
      assert amounts(parsed) == ["-5", "6"]
    end

    test "fails the whole body for a sign that is neither" do
      lines = [line(%{}), line(%{"AmountSign" => "?"})]

      assert Statements.parse(body(lines)) == {:error, :unexpected_response}

      assert Statements.parse(body([line(%{"AmountSign" => "x"})])) ==
               {:error, :unexpected_response}

      assert Statements.parse(body([line(%{"AmountSign" => ""})])) ==
               {:error, :unexpected_response}

      assert Statements.parse(body([line(%{"AmountSign" => nil})])) ==
               {:error, :unexpected_response}

      assert Statements.parse(body([line(%{"AmountSign" => 1})])) ==
               {:error, :unexpected_response}
    end

    test "reads an amount that is an integer and one that is a decimal" do
      body = """
      {"Statements": [
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "1", "Amount": 90, "AmountSign": "P"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "2", "Amount": 1.0, "AmountSign": "P"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "3", "Amount": 1157.98, "AmountSign": "P"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "4", "Amount": 1.005, "AmountSign": "X"}
      ]}
      """

      assert {:ok, parsed} = Statements.parse(body)
      assert amounts(parsed) == ["90", "1.0", "1157.98", "-1.005"]
    end

    test "reads an amount as it is written, not as the nearest float" do
      body = body([line(%{"Amount" => 0.1}), line(%{"Amount" => 0.2})])
      assert {:ok, %{statements: [first, second]}} = Statements.parse(body)

      assert Decimal.equal?(Decimal.add(first.amount, second.amount), Decimal.new("0.3"))
    end

    test "fails for an amount that is not a number" do
      assert Statements.parse(body([line(%{"Amount" => "12.50"})])) ==
               {:error, :unexpected_response}

      assert Statements.parse(body([line(%{"Amount" => nil})])) == {:error, :unexpected_response}
      assert Statements.parse(body([line(%{"Amount" => true})])) == {:error, :unexpected_response}

      assert Statements.parse(body([Map.delete(line(%{}), "Amount")])) ==
               {:error, :unexpected_response}
    end

    test "fails for an amount with an exponent that no amount has" do
      body = ~s({"Statements": [#{Jason.encode!(line(%{}))}]})
      hostile = String.replace(body, ~s("Amount":1), ~s("Amount":1e999999999))

      assert hostile != body
      assert Statements.parse(hostile) == {:error, :unexpected_response}
    end

    test "keeps the transaction id a string, with its zeros" do
      assert {:ok, %{statements: [statement]}} =
               Statements.parse(body([line(%{"TransactionUN" => "0002026100509935"})]))

      assert statement.transaction_id == "0002026100509935"
    end

    test "fails for a transaction id that is not a string" do
      assert Statements.parse(body([line(%{"TransactionUN" => 202_610_050_993_559_457})])) ==
               {:error, :unexpected_response}
    end

    test "fails when a field is missing, null or not a string" do
      for field <- ["EntryDate", "Valeur", "Reason", "Branch", "TransactionUN", "AmountSign"] do
        assert Statements.parse(body([Map.delete(line(%{}), field)])) ==
                 {:error, :unexpected_response}

        assert Statements.parse(body([line(%{field => nil})])) == {:error, :unexpected_response}
        assert Statements.parse(body([line(%{field => 7})])) == {:error, :unexpected_response}
      end
    end

    test "fails the whole body when one line cannot be read" do
      assert Statements.parse(body([line(%{}), %{"Reason" => "only this"}, line(%{})])) ==
               {:error, :unexpected_response}

      assert Statements.parse(body([line(%{}), "line"])) == {:error, :unexpected_response}
    end

    test "gives no lines for an empty list" do
      assert {:ok, %{statements: []}} = Statements.parse(body([]))
    end

    test "fails for what is not the statements of the bank" do
      assert Statements.parse("not json") == {:error, :unexpected_response}
      assert Statements.parse("") == {:error, :unexpected_response}
      assert Statements.parse("[]") == {:error, :unexpected_response}
      assert Statements.parse("null") == {:error, :unexpected_response}
      assert Statements.parse(~s({"ResultCode": 1})) == {:error, :unexpected_response}
      assert Statements.parse(~s({"Statements": null})) == {:error, :unexpected_response}
      assert Statements.parse(~s({"Statements": {}})) == {:error, :unexpected_response}
      assert Statements.parse(nil) == {:error, :unexpected_response}
    end
  end

  describe "parse/1 with the details of a line" do
    test "makes the details a statement lists the detail of the line, even when they are blank" do
      body = """
      {"Statements": [
        {"EntryDate": "7/7/2026", "Valeur": "7/7/2026", "Reason": "A", "Branch": "96", "TransactionUN": "1", "Amount": 100, "AmountSign": "#{@chi}",
         "StatementDetails": [{"SenderDetails": "x", "AdditionalInformation": "note", "ConversionDetails": ""}]},
        {"EntryDate": "7/7/2026", "Valeur": "7/7/2026", "Reason": "B", "Branch": "96", "TransactionUN": "1", "Amount": 9, "AmountSign": "#{@chi}",
         "StatementDetails": [{"SenderDetails": "", "AdditionalInformation": "", "ConversionDetails": ""}]},
        {"EntryDate": "7/7/2026", "Valeur": "7/7/2026", "Reason": "C", "Branch": "96", "TransactionUN": "2", "Amount": 1, "AmountSign": "#{@pi}",
         "StatementDetails": []},
        {"EntryDate": "7/7/2026", "Valeur": "7/7/2026", "Reason": "D", "Branch": "96", "TransactionUN": "3", "Amount": 1, "AmountSign": "#{@pi}"},
        {"EntryDate": "7/7/2026", "Valeur": "7/7/2026", "Reason": "E", "Branch": "96", "TransactionUN": "4", "Amount": 1, "AmountSign": "#{@pi}",
         "StatementDetails": null}
      ]}
      """

      assert {:ok, %{statements: statements}} = Statements.parse(body)

      assert Enum.map(statements, & &1.detail) == [
               %Detail{
                 conversion_details: "",
                 sender_details: "x",
                 additional_information: "note"
               },
               %Detail{conversion_details: "", sender_details: "", additional_information: ""},
               nil,
               nil,
               nil
             ]
    end

    test "joins the texts of several entries" do
      entries = [
        %{"SenderDetails" => "x"},
        %{"SenderDetails" => "y", "AdditionalInformation" => "note"}
      ]

      assert {:ok, %{statements: [statement]}} =
               Statements.parse(body([line(%{"StatementDetails" => entries})]))

      assert statement.detail == %Detail{sender_details: "x | y", additional_information: "note"}
    end

    test "fails when the details are not a list of objects of texts" do
      for details <- ["x", %{}, 5, [1], [%{"SenderDetails" => 5}], [%{"SenderDetails" => %{}}]] do
        assert Statements.parse(body([line(%{"StatementDetails" => details})])) ==
                 {:error, :unexpected_response}
      end
    end
  end

  describe "parse/1 with the balances" do
    test "reads the balances and their signs" do
      rest = %{
        "PreviousGrossBalance" => 1000.5,
        "PreviousGrossBalanceSign" => @pi,
        "NewGrossBalance" => 20,
        "NewGrossBalanceSign" => "X"
      }

      assert {:ok, parsed} = Statements.parse(body([], rest))
      assert Decimal.equal?(parsed.previous_balance, Decimal.new("1000.5"))
      assert parsed.previous_balance_sign == :credit
      assert Decimal.equal?(parsed.new_balance, Decimal.new("20"))
      assert parsed.new_balance_sign == :debit
    end

    test "gives nil for the ones that are null or missing" do
      assert {:ok, parsed} =
               Statements.parse(
                 body([], %{"PreviousGrossBalance" => nil, "NewGrossBalance" => 3})
               )

      assert %{previous_balance: nil, previous_balance_sign: nil, new_balance_sign: nil} = parsed
      assert Decimal.equal?(parsed.new_balance, Decimal.new("3"))
    end

    test "fails for a balance that is not a number or a sign that is not one" do
      assert Statements.parse(body([], %{"NewGrossBalance" => "3"})) ==
               {:error, :unexpected_response}

      assert Statements.parse(body([], %{"NewGrossBalanceSign" => "?"})) ==
               {:error, :unexpected_response}

      assert Statements.parse(body([], %{"PreviousGrossBalanceSign" => 1})) ==
               {:error, :unexpected_response}
    end
  end
end
