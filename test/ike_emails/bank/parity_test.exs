defmodule IkeEmails.Bank.ParityTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Detail
  alias IkeEmails.Bank.Alpha.Statement
  alias IkeEmails.Bank.Parity

  defp row(fields \\ []) do
    Map.merge(
      %{
        date: "2026-10-19",
        value_date: "2026-10-17",
        description: "SHOP",
        branch: "99",
        transaction_id: "1",
        amount: "-9.00",
        conversion_details: "",
        sender_details: "",
        additional_information: ""
      },
      Map.new(fields)
    )
  end

  describe "columns/0" do
    test "are those of the file of the crawler" do
      assert Enum.join(Parity.columns(), ",") ==
               "date,value_date,description,branch,transaction_id,amount," <>
                 "conversion_details,sender_details,additional_information"
    end
  end

  describe "rows_from_csv/1" do
    test "makes a map of each record after the header" do
      records = [Parity.columns(), ~w(a b c d e f g h i), ~w(1 2 3 4 5 6 7 8 9)]

      assert {:ok, [first, second]} = Parity.rows_from_csv(records)
      assert first.date == "a" and first.additional_information == "i"
      assert second.description == "3" and second.amount == "6"
    end

    test "has no row in a header only" do
      assert Parity.rows_from_csv([Parity.columns()]) == {:ok, []}
    end

    test "refuses nothing, another header, and a record of another size" do
      assert Parity.rows_from_csv([]) == {:error, :empty}
      assert Parity.rows_from_csv([~w(a b), ~w(1 2)]) == {:error, :header}
      assert Parity.rows_from_csv([Parity.columns(), ~w(1 2 3)]) == {:error, {:columns, 1}}

      assert Parity.rows_from_csv([Parity.columns(), ~w(a b c d e f g h i), ~w(1)]) ==
               {:error, {:columns, 2}}
    end
  end

  describe "compare/2" do
    test "has nothing that differs in rows that are the same" do
      rows = [row(), row(transaction_id: "2", description: "OTHER")]
      report = Parity.compare(rows, rows)

      assert report == %{
               csv: 2,
               rebuilt: 2,
               identical: 2,
               csv_only: 0,
               rebuilt_only: 0,
               in_order: [],
               by_key: []
             }

      assert Parity.identical?(report)
    end

    test "takes an empty field of the file and a nil of the rebuilt row for the same" do
      assert Parity.identical?(Parity.compare([row()], [row(sender_details: nil)]))
    end

    test "counts the rows that differ in a field, in the order of the columns" do
      csv = [row(), row(transaction_id: "2"), row(transaction_id: "3")]

      rebuilt = [
        row(branch: "1"),
        row(transaction_id: "2", branch: "1", value_date: "2026-01-01"),
        row(transaction_id: "3")
      ]

      report = Parity.compare(csv, rebuilt)

      assert report.identical == 1
      assert report.in_order == [value_date: 1, branch: 2]
      assert report.by_key == [value_date: 1, branch: 2]
      assert {report.csv_only, report.rebuilt_only} == {0, 0}
      refute Parity.identical?(report)
    end

    test "counts the rows that only one side has by the key, and the fields of the key apart" do
      csv = [row(), row(transaction_id: "2", amount: "1.00")]
      rebuilt = [row(), row(transaction_id: "2", amount: "1.01")]

      report = Parity.compare(csv, rebuilt)

      assert report.identical == 1
      assert report.in_order == [amount: 1]
      assert {report.csv_only, report.rebuilt_only} == {1, 1}
      assert report.by_key == []
    end

    test "counts a key that is in several rows once for each row" do
      csv = [row(), row(), row()]
      rebuilt = [row(), row()]

      report = Parity.compare(csv, rebuilt)

      assert {report.csv, report.rebuilt, report.identical} == {3, 2, 2}
      assert {report.csv_only, report.rebuilt_only} == {1, 0}
      refute Parity.identical?(report)
    end

    test "sees rows in another order as different in order, but not by the key" do
      a = row()
      b = row(transaction_id: "2")

      report = Parity.compare([a, b], [b, a])

      assert report.identical == 0
      assert {report.csv_only, report.rebuilt_only} == {0, 0}
      assert report.by_key == []
      refute Parity.identical?(report)
    end

    test "is not identical for no rows" do
      refute Parity.identical?(Parity.compare([], []))
    end
  end

  describe "lines/1" do
    test "holds the numbers and the names of the fields, and no value" do
      report = Parity.compare([row(description: "SECRET SHOP")], [row(description: "OTHER SHOP")])

      text = report |> Parity.lines() |> Enum.join("\n")

      assert text =~ "rows in transactions.csv: 1"
      assert text =~ "fields that differ, rows paired in order:\n  description: 1"
      refute text =~ "SECRET"
      refute text =~ "OTHER"
    end

    test "has no list of fields when none differs" do
      lines = [row()] |> Parity.compare([row()]) |> Parity.lines()

      assert length(lines) == 5
    end
  end

  defp statement(id, fields \\ []) do
    struct!(
      Statement,
      Keyword.merge(
        [
          entry_date: "1/1/2026",
          value_date: "1/1/2026",
          reason: "x",
          branch: "99",
          transaction_id: id,
          amount: Decimal.new("-1")
        ],
        fields
      )
    )
  end

  describe "without_details/2" do
    test "counts the lines with no detail of their own and none in the details" do
      statements = [
        statement("1"),
        statement("2"),
        statement("3", detail: %Detail{}),
        statement("4", detail: %Detail{sender_details: "x"}),
        statement("5")
      ]

      details = %{"2" => %Detail{sender_details: "from the call"}, "9" => %Detail{}}

      assert Parity.without_details(statements, details) == 2
    end

    test "counts each line of an id that has no details" do
      statements = [statement("1"), statement("1"), statement("1", detail: %Detail{})]

      assert Parity.without_details(statements, %{}) == 2
      assert Parity.without_details(statements, %{"1" => %Detail{}}) == 0
    end

    test "counts none of no lines" do
      assert Parity.without_details([], %{}) == 0
    end
  end

  describe "crawl_failed/1" do
    test "reads the number of the failed details and nothing else" do
      assert Parity.crawl_failed(~s({"complete": true, "failed": 3, "stopped": null})) == 3
      assert Parity.crawl_failed(~s({"failed": 0})) == 0
    end

    test "is nil for what does not say how many failed" do
      for text <- [
            "",
            "not json",
            "[]",
            "3",
            "{}",
            ~s({"failed": null}),
            ~s({"failed": "3"}),
            ~s({"failed": 2.5}),
            ~s({"failed": -1}),
            ~s({"failed": [3]}),
            ~s({"Failed": 3})
          ] do
        assert Parity.crawl_failed(text) == nil, text
      end
    end
  end

  describe "context_lines/1" do
    test "holds the three numbers" do
      context = %{rejected: 2, without_details: 7, failed: 3}

      assert Parity.context_lines(context) == [
               "lines left out of the rebuilt rows for a date that cannot be read: 2",
               "lines with no detail of their own and none in details.json: 7",
               "details that failed in the crawl, from crawl.json: 3"
             ]
    end

    test "says a zero too, and has no line for a crawl.json that is not there" do
      lines = Parity.context_lines(%{rejected: 0, without_details: 0, failed: nil})

      assert length(lines) == 2
      assert Enum.all?(lines, &(&1 =~ ": 0"))

      assert [_, _, "details that failed in the crawl, from crawl.json: 0"] =
               Parity.context_lines(%{rejected: 0, without_details: 0, failed: 0})
    end
  end
end
