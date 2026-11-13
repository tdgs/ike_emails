defmodule IkeEmails.Bank.Alpha.EStatementsTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.EStatement
  alias IkeEmails.Bank.Alpha.EStatements

  # The shape of a real getAccountEStatements response, newest first, but for the first
  # entry: the real list has only months that were issued. A month that has not been is
  # not seen yet, and is expected to have no id and no date.
  @estatements_response """
  {
    "ResultCode": 0,
    "EStatements": [
      {
        "ClosingBalance": 100.5,
        "DateFrom": "2026-10-01",
        "DateTo": "2026-10-31",
        "EStatementIssued": false,
        "EstatementID": null,
        "IssuedDate": null,
        "OpeningBalance": 90
      },
      {
        "ClosingBalance": 90,
        "DateFrom": "2026-09-01",
        "DateTo": "2026-09-30",
        "EStatementIssued": true,
        "EstatementID": "AAAA/bbb+ccc=",
        "IssuedDate": "2026-10-02",
        "OpeningBalance": 80.25
      },
      {
        "ClosingBalance": 80.25,
        "DateFrom": "2026-08-01",
        "DateTo": "2026-08-31",
        "EStatementIssued": true,
        "EstatementID": "DDDD/eee+fff=",
        "IssuedDate": "2026-09-02",
        "OpeningBalance": 70
      }
    ]
  }
  """

  defp estatement(id, date_from, date_to, issued_date \\ "2026-10-02") do
    %EStatement{id: id, date_from: date_from, date_to: date_to, issued_date: issued_date}
  end

  defp list_with(entry) do
    Jason.encode!(%{"EStatements" => [Map.merge(issued_entry(), entry)]})
  end

  defp issued_entry do
    %{
      "EStatementIssued" => true,
      "EstatementID" => "A",
      "DateFrom" => "2026-09-01",
      "DateTo" => "2026-09-30",
      "IssuedDate" => "2026-10-02"
    }
  end

  describe "parse/1" do
    test "keeps the statements the bank has issued, in the order given" do
      assert EStatements.parse(@estatements_response) ==
               {:ok,
                [
                  estatement("AAAA/bbb+ccc=", "2026-09-01", "2026-09-30", "2026-10-02"),
                  estatement("DDDD/eee+fff=", "2026-08-01", "2026-08-31", "2026-09-02")
                ]}
    end

    test "gives none for a list of none" do
      assert EStatements.parse(~s({"ResultCode": 0, "EStatements": []})) == {:ok, []}
    end

    test "leaves out the ones not issued, whatever else they have or lack" do
      body =
        ~s({"EStatements": [{"EStatementIssued": false}, {"EStatementIssued": false, "DateFrom": 5}]})

      assert EStatements.parse(body) == {:ok, []}
    end

    test "accepts the dates of the shape yyyy-mm-dd" do
      assert {:ok, [_]} = EStatements.parse(list_with(%{}))

      assert {:ok, [_]} =
               EStatements.parse(
                 list_with(%{"DateFrom" => "2025-12-01", "DateTo" => "2025-12-31"})
               )
    end

    test "fails the whole list for a date that is not of that shape, since the file is named after it" do
      for date <- [
            "../../x/y",
            "30/09/2026",
            "2026-9-01",
            "2026-09-0+",
            "2026-09-01 ",
            "2026-09-01\n",
            " 2026-09-01",
            "2026-09-011",
            "02026-09-01",
            "2026/09/01",
            "20260901",
            "2026-09",
            "",
            "20x6-09-01",
            "\u{0662}\u{0660}\u{0662}\u{0666}-09-01"
          ] do
        assert EStatements.parse(list_with(%{"DateFrom" => date})) ==
                 {:error, :unexpected_response},
               inspect(date)

        assert EStatements.parse(list_with(%{"DateTo" => date})) == {:error, :unexpected_response},
               inspect(date)
      end
    end

    test "fails the whole list when one entry is not right, though the others are" do
      good = issued_entry()
      body = Jason.encode!(%{"EStatements" => [good, Map.put(good, "DateTo", "x"), good]})

      assert EStatements.parse(body) == {:error, :unexpected_response}
    end

    test "fails for an issued statement that lacks what it needs, or has it of another type" do
      for field <- ["EstatementID", "DateFrom", "DateTo", "IssuedDate"] do
        assert EStatements.parse(list_with(%{field => nil})) == {:error, :unexpected_response}
        assert EStatements.parse(list_with(%{field => 5})) == {:error, :unexpected_response}

        body = Jason.encode!(%{"EStatements" => [Map.delete(issued_entry(), field)]})
        assert EStatements.parse(body) == {:error, :unexpected_response}
      end
    end

    test "fails for an entry that says nothing about being issued, or says it with a text" do
      assert EStatements.parse(~s({"EStatements": [{}]})) == {:error, :unexpected_response}

      assert EStatements.parse(~s({"EStatements": [{"EStatementIssued": null}]})) ==
               {:error, :unexpected_response}

      assert EStatements.parse(~s({"EStatements": [{"EStatementIssued": "true"}]})) ==
               {:error, :unexpected_response}

      assert EStatements.parse(~s({"EStatements": ["x"]})) == {:error, :unexpected_response}
    end

    test "fails for what is not the list of the bank" do
      assert EStatements.parse(~s({"ResultCode": 1})) == {:error, :unexpected_response}
      assert EStatements.parse(~s({"EStatements": null})) == {:error, :unexpected_response}
      assert EStatements.parse(~s({"EStatements": {}})) == {:error, :unexpected_response}
      assert EStatements.parse("[]") == {:error, :unexpected_response}
      assert EStatements.parse("not json") == {:error, :unexpected_response}
      assert EStatements.parse(nil) == {:error, :unexpected_response}
    end
  end

  describe "latest/1" do
    test "is the statement that ends last, however the bank orders them" do
      august = estatement("D", "2026-08-01", "2026-08-31", "2026-09-02")
      september = estatement("A", "2026-09-01", "2026-09-30", "2026-10-02")
      december = estatement("Z", "2025-12-01", "2025-12-31", "2026-01-05")

      assert EStatements.latest([september, august, december]) == {:ok, september}
      assert EStatements.latest([august, december, september]) == {:ok, september}
      assert EStatements.latest([december, august]) == {:ok, august}
      assert EStatements.latest([august]) == {:ok, august}
    end

    test "is none for none" do
      assert EStatements.latest([]) == {:error, :none}
    end

    test "is the one of the year before when the month is a larger number" do
      # 2025-12 is after 2025-02, though 12 sorts before 2 as a number of digits
      february = estatement("B", "2025-02-01", "2025-02-28", "2025-03-03")
      december = estatement("C", "2025-12-01", "2025-12-31", "2026-01-05")

      assert EStatements.latest([february, december]) == {:ok, december}
      assert EStatements.latest([december, february]) == {:ok, december}
    end

    test "is the first of two that end the same day" do
      first = estatement("first", "2026-09-01", "2026-09-30")
      second = estatement("second", "2026-09-02", "2026-09-30")

      assert EStatements.latest([first, second]) == {:ok, first}
      assert EStatements.latest([second, first]) == {:ok, second}
    end

    test "is the one that ends in the later year" do
      older = estatement("older", "2025-12-01", "2025-12-31")
      newer = estatement("newer", "2026-01-01", "2026-01-31")

      assert EStatements.latest([newer, older]) == {:ok, newer}
      assert EStatements.latest([older, newer]) == {:ok, newer}
    end
  end

  describe "file_name/1 and month/1" do
    test "name the file after the month the statement starts in" do
      statement = estatement("A", "2026-09-01", "2026-09-30")

      assert EStatements.file_name(statement) == "estatement-2026-09.pdf"
      assert EStatements.month(statement) == "2026-09"
    end

    test "take the month from the first day, not from the last" do
      statement = estatement("A", "2025-12-15", "2026-01-14")

      assert EStatements.file_name(statement) == "estatement-2025-12.pdf"
      assert EStatements.month(statement) == "2025-12"
    end

    test "do not use the id, which can have a slash" do
      statement = estatement("../../etc/passwd", "2026-01-01", "2026-01-31", "2026-02-03")

      assert EStatements.file_name(statement) == "estatement-2026-01.pdf"
    end

    test "are those of the statements that were parsed" do
      assert {:ok, statements} = EStatements.parse(@estatements_response)

      assert Enum.map(statements, &EStatements.file_name/1) == [
               "estatement-2026-09.pdf",
               "estatement-2026-08.pdf"
             ]

      assert Enum.map(statements, &EStatements.month/1) == ["2026-09", "2026-08"]
    end
  end
end
