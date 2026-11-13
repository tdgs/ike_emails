defmodule IkeEmails.Bank.Alpha.RowsTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Rows
  alias IkeEmails.Bank.Alpha.Statement
  alias IkeEmails.Bank.Alpha.Statements

  defp statement(fields) do
    defaults = [
      entry_date: "1/1/2026",
      value_date: "1/1/2026",
      reason: "x",
      branch: "99",
      transaction_id: "1",
      amount: Decimal.new("-1")
    ]

    struct!(Statement, Keyword.merge(defaults, fields))
  end

  defp single_row(fields, details \\ %{}) do
    assert {:ok, [row], []} = Rows.build([statement(fields)], details)
    row
  end

  defp amount(value), do: single_row(amount: Decimal.new(value)).amount

  describe "build/2" do
    test "makes the rows of the lines, in their order" do
      statements = [
        statement(
          entry_date: "19/10/2026",
          value_date: "17/10/2026",
          reason: "ANTHROPIC* CLAUDE SU",
          branch: "99",
          transaction_id: "1",
          amount: Decimal.new("-90")
        ),
        statement(
          entry_date: "5/10/2026",
          value_date: "2/10/2026",
          reason: "GITHUB, INC.",
          branch: "99",
          transaction_id: "2",
          amount: Decimal.new("126.51")
        ),
        statement(
          entry_date: "2/10/2026",
          value_date: "2/10/2026",
          reason: ~s(SAYS "HI"),
          branch: "949",
          transaction_id: "3",
          amount: Decimal.new("1157.98")
        )
      ]

      assert Rows.build(statements, %{}) ==
               {:ok,
                [
                  %{
                    date: "2026-10-19",
                    value_date: "2026-10-17",
                    description: "ANTHROPIC* CLAUDE SU",
                    branch: "99",
                    transaction_id: "1",
                    amount: "-90.00",
                    conversion_details: nil,
                    sender_details: nil,
                    additional_information: nil
                  },
                  %{
                    date: "2026-10-05",
                    value_date: "2026-10-02",
                    description: "GITHUB, INC.",
                    branch: "99",
                    transaction_id: "2",
                    amount: "126.51",
                    conversion_details: nil,
                    sender_details: nil,
                    additional_information: nil
                  },
                  %{
                    date: "2026-10-02",
                    value_date: "2026-10-02",
                    description: ~s(SAYS "HI"),
                    branch: "949",
                    transaction_id: "3",
                    amount: "1157.98",
                    conversion_details: nil,
                    sender_details: nil,
                    additional_information: nil
                  }
                ], []}
    end

    test "makes no rows of no lines" do
      assert Rows.build([], %{}) == {:ok, [], []}
    end

    test "gives a line that lists no details of its own those of the call for its id, or none" do
      details = %{
        "1" => %Detail{conversion_details: "20,00 USD", sender_details: "OPENAI SUBSCR"},
        "3" => %Detail{sender_details: ~s(John "J" Doe), additional_information: "rent, october"}
      }

      statements = [
        statement(reason: "OPENAI", transaction_id: "1", amount: Decimal.new("-18.01")),
        statement(reason: "no details", transaction_id: "2", amount: Decimal.new("5")),
        statement(reason: "transfer", transaction_id: "3", amount: Decimal.new("100"))
      ]

      assert {:ok, [first, second, third], []} = Rows.build(statements, details)

      assert Map.take(first, [
               :amount,
               :conversion_details,
               :sender_details,
               :additional_information
             ]) ==
               %{
                 amount: "-18.01",
                 conversion_details: "20,00 USD",
                 sender_details: "OPENAI SUBSCR",
                 additional_information: nil
               }

      assert Map.take(second, [
               :amount,
               :conversion_details,
               :sender_details,
               :additional_information
             ]) ==
               %{
                 amount: "5.00",
                 conversion_details: nil,
                 sender_details: nil,
                 additional_information: nil
               }

      assert Map.take(third, [
               :amount,
               :conversion_details,
               :sender_details,
               :additional_information
             ]) ==
               %{
                 amount: "100.00",
                 conversion_details: nil,
                 sender_details: ~s(John "J" Doe),
                 additional_information: "rent, october"
               }
    end

    test "keeps the own details of each line that shares an id, whatever the call has for the id" do
      details = %{
        "1" => %Detail{sender_details: "from the call"},
        "2" => %Detail{sender_details: "from the call"}
      }

      statements = [
        statement(
          reason: "transfer",
          transaction_id: "1",
          amount: Decimal.new("-100"),
          detail: %Detail{sender_details: "John", additional_information: "rent"}
        ),
        statement(
          reason: "fee",
          transaction_id: "1",
          amount: Decimal.new("-9"),
          detail: %Detail{}
        ),
        statement(reason: "recent", transaction_id: "2", amount: Decimal.new("-1"))
      ]

      assert {:ok, rows, []} = Rows.build(statements, details)

      assert Enum.map(
               rows,
               &{&1.description, &1.conversion_details, &1.sender_details,
                &1.additional_information}
             ) ==
               [
                 {"transfer", nil, "John", "rent"},
                 {"fee", nil, nil, nil},
                 {"recent", nil, "from the call", nil}
               ]
    end

    test "cleans the description and the three texts of the detail" do
      details = %{
        "1" => %Detail{
          conversion_details: "",
          sender_details: "ΑΝΤΗRΟΡΙC* CLΑUDΕ SUΒ",
          additional_information: "ΒΕΒΑΙΩΜΕΝΕΣ ΟΦΕΙΛΕΣ ΜΑRΙΑ"
        }
      }

      assert {:ok, [row], []} = Rows.build([statement(reason: "ΕLΟRUS              ")], details)

      assert row.description == "ELORUS"
      assert row.conversion_details == nil
      assert row.sender_details == "ANTHROPIC* CLAUDE SUB"
      assert row.additional_information == "ΒΕΒΑΙΩΜΕΝΕΣ ΟΦΕΙΛΕΣ MARIA"
    end

    test "makes a text of only spaces, in the detail, nil" do
      detail = %Detail{
        conversion_details: "   ",
        sender_details: "\u{200E}\u{200F}",
        additional_information: "x"
      }

      assert %{conversion_details: nil, sender_details: nil, additional_information: "x"} =
               single_row([detail: detail], %{})
    end

    test "does not clean or trim the branch or the transaction id" do
      row = single_row(branch: " \u{0391}B ", transaction_id: " 0001 ")

      assert row.branch == " \u{0391}B "
      assert row.transaction_id == " 0001 "
      assert single_row(branch: "").branch == ""
    end

    test "cleans the description, to nothing if there is nothing" do
      assert single_row(reason: "   ").description == ""
    end
  end

  describe "build/2 dates" do
    test "writes the dates of the bank as ISO dates, with or without zeros" do
      row = single_row(entry_date: "5/10/2026", value_date: "05/01/2026")
      assert row.date == "2026-10-05"
      assert row.value_date == "2026-01-05"

      row = single_row(entry_date: "31/12/2026", value_date: "1/1/2026")
      assert row.date == "2026-12-31"
      assert row.value_date == "2026-01-01"
    end

    test "accepts the 29th of February of a leap year" do
      assert single_row(entry_date: "29/2/2028").date == "2028-02-29"
    end

    test "rejects a line whose date is not d/M/yyyy, and returns its transaction id" do
      for date <- [
            "",
            "2026-10-05",
            "5/10",
            "5/10/26",
            "5/10/2026/1",
            "5/10/2026 12:00:00 πμ",
            "5/10/2026 12:00:00",
            "5/10/2026T12:00:00",
            " 5/10/2026",
            "5/10/2026\n",
            "5//2026",
            "a/10/2026",
            "5/b/2026",
            "5/10/year",
            "005/10/2026",
            "+5/10/2026",
            "-5/10/2026",
            "5.10.2026",
            "\u{0665}/10/2026"
          ] do
        assert Rows.build([statement(entry_date: date, transaction_id: "7")], %{}) ==
                 {:ok, [], ["7"]},
               inspect(date)

        assert Rows.build([statement(value_date: date, transaction_id: "7")], %{}) ==
                 {:ok, [], ["7"]},
               inspect(date)
      end
    end

    test "rejects a line whose day is not in the calendar, and returns its transaction id" do
      for date <- [
            "0/10/2026",
            "5/0/2026",
            "32/1/2026",
            "31/4/2026",
            "30/2/2026",
            "29/2/2026",
            "1/13/2026"
          ] do
        assert Rows.build([statement(entry_date: date, transaction_id: "7")], %{}) ==
                 {:ok, [], ["7"]},
               date
      end
    end

    test "makes the rows of the other lines, in their order, when some lines are rejected" do
      statements = [
        statement(transaction_id: "1"),
        statement(value_date: "x", transaction_id: "2"),
        statement(transaction_id: "3"),
        statement(entry_date: "31/2/2026", transaction_id: "4"),
        statement(transaction_id: "5")
      ]

      assert {:ok, rows, rejected} = Rows.build(statements, %{})

      assert Enum.map(rows, & &1.transaction_id) == ["1", "3", "5"]
      assert rejected == ["2", "4"]
    end

    test "returns the id once for each line that is rejected, also when lines share it" do
      statements = [
        statement(transaction_id: "9", entry_date: "x", amount: Decimal.new("-1")),
        statement(transaction_id: "9", amount: Decimal.new("-2")),
        statement(transaction_id: "9", value_date: "y", amount: Decimal.new("-3")),
        statement(transaction_id: "8", entry_date: "z")
      ]

      assert {:ok, [row], ["9", "9", "8"]} = Rows.build(statements, %{})
      assert row.amount == "-2.00"
    end

    test "has the ids of the lines in the rejected, and nothing of their dates" do
      statements = [
        statement(entry_date: "31/04/2026", value_date: "SECRET-DATE", transaction_id: "7")
      ]

      assert {:ok, [], rejected} = Rows.build(statements, %{})

      assert rejected == ["7"]
      refute inspect(rejected) =~ "SECRET"
      refute inspect(rejected) =~ "31/04"
    end

    test "rejects a line whatever its detail, and only that line" do
      details = %{"1" => %Detail{sender_details: "from the call"}}

      statements = [
        statement(transaction_id: "1", entry_date: "x"),
        statement(transaction_id: "1", amount: Decimal.new("-2"))
      ]

      assert {:ok, [row], ["1"]} = Rows.build(statements, details)
      assert {row.amount, row.sender_details} == {"-2.00", "from the call"}
    end
  end

  describe "build/2 amounts" do
    test "writes whole cents, with the sign, and no thousands separator" do
      assert amount("-90") == "-90.00"
      assert amount("126.51") == "126.51"
      assert amount("1157.98") == "1157.98"
      assert amount("1234567.8") == "1234567.80"
      assert amount("-0.05") == "-0.05"
      assert amount("0.05") == "0.05"
      assert amount("5") == "5.00"
      assert amount("-18.01") == "-18.01"
    end

    test "writes an amount that is zero as 0.00" do
      assert amount("0") == "0.00"
      assert amount("0.00") == "0.00"
    end

    test "never writes -0.00" do
      assert amount("-0") == "0.00"
      assert amount("-0.0") == "0.00"
      assert amount("-0.001") == "0.00"
      assert amount("-0.004") == "0.00"
      assert single_row(amount: Decimal.negate(Decimal.new(0))).amount == "0.00"
    end

    test "rounds half a cent away from zero" do
      assert amount("0.005") == "0.01"
      assert amount("-0.005") == "-0.01"
      assert amount("0.015") == "0.02"
      assert amount("-0.015") == "-0.02"
      assert amount("2.675") == "2.68"
      assert amount("0.004") == "0.00"
      assert amount("0.0049") == "0.00"
      assert amount("-0.0051") == "-0.01"
      assert amount("-1.995") == "-2.00"
    end

    test "rounds the decimal as the bank wrote it, not the nearest float" do
      body = ~s({"Statements": [
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "1", "Amount": 1.005, "AmountSign": "P"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "2", "Amount": 1.005, "AmountSign": "X"}
      ]})

      assert {:ok, %{statements: statements}} = Statements.parse(body)
      assert {:ok, [credit, debit], []} = Rows.build(statements, %{})
      assert credit.amount == "1.01"
      assert debit.amount == "-1.01"
    end

    test "writes the amounts of integers and of decimals read from the JSON" do
      body = ~s({"Statements": [
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "1", "Amount": 90, "AmountSign": "X"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "2", "Amount": 90.0, "AmountSign": "X"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "3", "Amount": 1.2, "AmountSign": "P"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "4", "Amount": 1.1E2, "AmountSign": "P"},
        {"EntryDate": "1/1/2026", "Valeur": "1/1/2026", "Reason": "A", "Branch": "99", "TransactionUN": "5", "Amount": 0, "AmountSign": "X"}
      ]})

      assert {:ok, %{statements: statements}} = Statements.parse(body)
      assert {:ok, rows, []} = Rows.build(statements, %{})
      assert Enum.map(rows, & &1.amount) == ["-90.00", "-90.00", "1.20", "110.00", "0.00"]
    end
  end
end
