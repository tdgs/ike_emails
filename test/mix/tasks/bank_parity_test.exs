defmodule Mix.Tasks.Bank.ParityTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Bank.Parity

  @moduletag :tmp_dir

  # The Greek capitals that the bank writes in place of Latin letters
  @alpha <<0x391::utf8>>
  @chi <<0x3A7::utf8>>
  @pi <<0x3A0::utf8>>

  # What the crawler in Gleam wrote to transactions.csv for the statements below, by hand:
  # the nine columns of a row. The description of the first has a Greek Alpha in the bank's
  # text, the second has a comma, the third quotes, the fifth is padded and its details
  # have a line break
  @rows [
    ["2026-10-19", "2026-10-17", "ANTHROPIC* CLAUDE SU", "99", "1001", "-90.00", "", "", ""],
    ["2026-10-05", "2026-10-02", "GITHUB, INC.", "99", "1002", "126.51", "", "", ""],
    ["2026-10-02", "2026-10-02", ~s(SAYS "HI"), "949", "1003", "1157.98", "", "", ""],
    ["2026-10-02", "2026-10-02", "AMAZON EU", "99", "1004", "-18.01", "20,00 USD", "", "note"],
    [
      "2026-09-30",
      "2026-09-30",
      "TRANSFER",
      "99",
      "1005",
      "-50.50",
      "",
      "JOHN DOE",
      "line one\nline two"
    ]
  ]

  @header "date,value_date,description,branch,transaction_id,amount,conversion_details,sender_details,additional_information"

  # Values that must never be printed
  @secrets ["ANTHROPIC", "GITHUB", "SAYS", "AMAZON", "JOHN DOE", "1001", "1002", "1003", "1157"]

  setup %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    write_run(dir)
    %{dir: dir}
  end

  defp statement(date, value_date, reason, branch, id, amount, sign, details) do
    %{
      "EntryDate" => date,
      "Valeur" => value_date,
      "Reason" => reason,
      "Branch" => branch,
      "TransactionUN" => id,
      "Amount" => amount,
      "AmountSign" => sign,
      "StatementDetails" => details
    }
  end

  # `extra` are lines after the others, and `closing` the balance that they come to
  defp statements_json(opts \\ []) do
    opening = Keyword.get(opts, :opening, 1000)
    extra = Keyword.get(opts, :extra, [])
    closing = Keyword.get(opts, :closing, 2125.98)

    Jason.encode!(
      %{
        "ResultCode" => 0,
        "HasMore" => false,
        "Statements" => [
          statement(
            "19/10/2026",
            "17/10/2026",
            "  #{@alpha}NTHROPIC* CLAUDE SU   ",
            "99",
            "1001",
            90,
            @chi,
            nil
          ),
          statement("5/10/2026", "2/10/2026", "GITHUB, INC.", "99", "1002", 126.51, @pi, []),
          statement("2/10/2026", "2/10/2026", ~s(SAYS "HI"), "949", "1003", 1157.98, @pi, nil),
          statement("2/10/2026", "2/10/2026", "AMAZON EU", "99", "1004", 18.01, "X", [
            %{
              "ConversionDetails" => "20,00 USD",
              "SenderDetails" => "",
              "AdditionalInformation" => "note"
            }
          ]),
          statement("30/9/2026", "30/9/2026", "  TRANSFER  ", "99", "1005", 50.5, @chi, nil)
          | extra
        ],
        "PreviousGrossBalance" => opening,
        "PreviousGrossBalanceSign" => @pi,
        "NewGrossBalance" => closing,
        "NewGrossBalanceSign" => @pi
      },
      pretty: true
    )
  end

  # The crawler saved the answer of the bank for each id, as the JSON it is
  defp details_json do
    answer = fn id, detail ->
      %{
        "ResultCode" => 0,
        "Statements" => [%{"TransactionUN" => id, "StatementDetails" => [detail]}]
      }
    end

    Jason.encode!(
      %{
        "1005" =>
          answer.("1005", %{
            "ConversionDetails" => nil,
            "SenderDetails" => "JOHN DOE ",
            "AdditionalInformation" => "line one\nline two"
          }),
        "9999" => answer.("9999", %{"SenderDetails" => "NOT IN THE STATEMENTS"})
      },
      pretty: true
    )
  end

  # The way the crawler wrote a field
  defp field(value) do
    if String.contains?(value, [",", ~s("), "\n"]),
      do: ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s("),
      else: value
  end

  defp csv(rows, eol \\ "\n") do
    lines = for row <- rows, do: Enum.map_join(row, ",", &field/1)
    Enum.join([@header | lines], eol) <> eol
  end

  defp write_run(dir, opts \\ []) do
    File.write!(
      Path.join(dir, "statements.json"),
      Keyword.get(opts, :statements, statements_json())
    )

    File.write!(Path.join(dir, "details.json"), details_json())
    File.write!(Path.join(dir, "transactions.csv"), csv(Keyword.get(opts, :rows, @rows)))
  end

  defp output(lines \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> output([line | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp assert_no_secrets(text) do
    for secret <- @secrets, do: refute(text =~ secret, "the output has #{secret}")
  end

  describe "run/1 on a run that is the same" do
    test "says that the parity is 100%", %{dir: dir} do
      Parity.run([dir])

      output = output()
      assert output =~ "rows in transactions.csv: 5"
      assert output =~ "rows rebuilt from statements.json and details.json: 5"
      assert output =~ "paired in order: 5"
      assert output =~ "by transaction_id, amount and description: 0"
      assert output =~ "the lines add up to the balances of the bank"
      assert output =~ "parity 100%"
      refute output =~ "fields that differ"
      assert_no_secrets(output)
    end

    test "takes a file with carriage returns, and without the last line break", %{dir: dir} do
      File.write!(Path.join(dir, "transactions.csv"), csv(@rows, "\r\n"))
      Parity.run([dir])
      assert output() =~ "parity 100%"

      text = @rows |> csv() |> String.trim_trailing("\n")
      File.write!(Path.join(dir, "transactions.csv"), text)

      Parity.run([dir])

      assert output() =~ "parity 100%"
    end
  end

  describe "run/1 and the numbers that say why a run differs" do
    test "says how many lines have no detail, and none for the date or the crawl", %{dir: dir} do
      Parity.run([dir])

      output = output()
      assert output =~ "for a date that cannot be read: 0\n"
      assert output =~ "no detail of their own and none in details.json: 3\n"
      refute output =~ "from crawl.json"
      assert output =~ "parity 100%"
    end

    test "says the failed details of a crawl.json, and nothing else that is in it", %{dir: dir} do
      File.write!(
        Path.join(dir, "crawl.json"),
        ~s({"complete": false, "transactions": 5, "details": 2, "failed": 4, "stopped": "ANTHROPIC"})
      )

      Parity.run([dir])

      output = output()
      assert output =~ "details that failed in the crawl, from crawl.json: 4"
      assert output =~ "parity 100%"
      assert_no_secrets(output)
    end

    test "says nothing of a crawl.json that cannot be used, and does not fail for it", %{dir: dir} do
      for text <- ["", "ANTHROPIC", ~s({"failed": "ANTHROPIC"}), ~s({"failed": 1.5}), "[1]"] do
        File.write!(Path.join(dir, "crawl.json"), text)

        Parity.run([dir])

        output = output()
        refute output =~ "from crawl.json"
        refute output =~ "ANTHROPIC"
        assert output =~ "parity 100%"
      end
    end

    test "says how many lines it leaves out for a date that cannot be read", %{dir: dir} do
      odd = statement("31/2/2026", "30/2/2026", "ODD SHOP", "99", "1006", 10, @pi, nil)

      write_run(dir,
        statements: statements_json(extra: [odd], closing: 2135.98),
        rows: @rows ++ [["31/2/2026", "30/2/2026", "ODD SHOP", "99", "1006", "10.00", "", "", ""]]
      )

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      output = output()
      assert output =~ "rows in transactions.csv: 6"
      assert output =~ "rows rebuilt from statements.json and details.json: 5"
      assert output =~ "paired in order: 5"
      assert output =~ "only in transactions.csv, by transaction_id, amount and description: 1"
      assert output =~ "only in the rebuilt rows, by transaction_id, amount and description: 0"
      assert output =~ "for a date that cannot be read: 1\n"
      assert output =~ "no detail of their own and none in details.json: 4\n"
      assert output =~ "the lines add up to the balances of the bank"
      refute output =~ "parity 100%"
      assert error.message =~ "Parity is not 100%"

      for text <- [output, error.message] do
        assert_no_secrets(text)
        refute text =~ "ODD SHOP"
        refute text =~ "1006"
        refute text =~ "31/2"
        refute text =~ "30/2"
      end
    end

    test "still says the line was left out when the file has not got it either", %{dir: dir} do
      odd = statement("31/2/2026", "31/2/2026", "ODD SHOP", "99", "1006", 10, @pi, nil)
      write_run(dir, statements: statements_json(extra: [odd], closing: 2135.98))

      Parity.run([dir])

      output = output()
      assert output =~ "rows in transactions.csv: 5"
      assert output =~ "rows rebuilt from statements.json and details.json: 5"
      assert output =~ "for a date that cannot be read: 1\n"
      assert output =~ "parity 100%"
    end
  end

  describe "run/1 on a run that is not the same" do
    test "names the fields that differ, and prints none of the values", %{dir: dir} do
      rows =
        @rows
        |> List.update_at(0, &List.replace_at(&1, 2, "CHANGED DESCRIPTION"))
        |> List.update_at(2, &List.replace_at(&1, 5, "1157.99"))

      write_run(dir, rows: rows)

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      output = output()
      assert output =~ "rows identical on all nine fields, paired in order: 3"
      assert output =~ "only in transactions.csv, by transaction_id, amount and description: 2"
      assert output =~ "only in the rebuilt rows, by transaction_id, amount and description: 2"
      assert output =~ "fields that differ, rows paired in order:\n  description: 1\n  amount: 1"
      refute output =~ "parity 100%"

      for text <- [output, error.message] do
        assert_no_secrets(text)
        refute text =~ "CHANGED"
        refute text =~ "99"
      end
    end

    test "names a field of the optional ones too", %{dir: dir} do
      rows = List.update_at(@rows, 4, &List.replace_at(&1, 7, "SOMEONE ELSE"))
      write_run(dir, rows: rows)

      assert_raise Mix.Error, fn -> Parity.run([dir]) end

      output = output()
      assert output =~ "fields that differ, rows paired in order:\n  sender_details: 1"

      assert output =~
               "fields that differ, rows paired by transaction_id, amount and description:"

      assert output =~ "only in transactions.csv, by transaction_id, amount and description: 0"
      refute output =~ "SOMEONE"
    end

    test "fails when the file has fewer rows", %{dir: dir} do
      write_run(dir, rows: Enum.take(@rows, 4))

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      output = output()
      assert output =~ "rows in transactions.csv: 4"
      assert output =~ "rows rebuilt from statements.json and details.json: 5"
      assert output =~ "only in the rebuilt rows, by transaction_id, amount and description: 1"
      assert error.message =~ "Parity is not 100%"
    end

    test "fails when the rows are the same but not in the same order", %{dir: dir} do
      [first, second | rest] = @rows
      write_run(dir, rows: [second, first | rest])

      assert_raise Mix.Error, fn -> Parity.run([dir]) end

      output = output()
      assert output =~ "paired in order: 3"
      assert output =~ "only in transactions.csv, by transaction_id, amount and description: 0"
    end

    test "fails when the lines do not add up to the balances, though the rows are the same", %{
      dir: dir
    } do
      write_run(dir, statements: statements_json(opening: 1001))

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      assert output() =~ "the lines do NOT add up to the balances of the bank"
      assert error.message =~ "do not add up"
    end

    test "fails for a file of no rows", %{dir: dir} do
      File.write!(Path.join(dir, "statements.json"), ~s({"Statements": []}))
      File.write!(Path.join(dir, "details.json"), "{}")
      File.write!(Path.join(dir, "transactions.csv"), @header <> "\n")

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      assert error.message =~ "no rows"
    end
  end

  describe "run/1 on files it cannot use" do
    test "fails for a file that is not a transactions.csv, without printing it", %{dir: dir} do
      File.write!(Path.join(dir, "transactions.csv"), "id,secret\n1,ANTHROPIC\n")

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      assert error.message =~ "transactions.csv"
      assert_no_secrets(error.message)
    end

    test "fails for a record of the wrong size, saying which, but not what is in it", %{dir: dir} do
      File.write!(Path.join(dir, "transactions.csv"), @header <> "\n1,ANTHROPIC,3\n")

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      assert error.message =~ "columns"
      assert_no_secrets(error.message)
    end

    test "fails for a statements file that is not the bank's", %{dir: dir} do
      File.write!(Path.join(dir, "statements.json"), ~s({"Statements": "ANTHROPIC"}))

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      assert error.message =~ "statements.json"
      assert_no_secrets(error.message)
    end

    test "fails for a details file that is not an object", %{dir: dir} do
      File.write!(Path.join(dir, "details.json"), ~s(["ANTHROPIC"]))

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      assert error.message =~ "rows again"
      assert_no_secrets(error.message)
    end

    test "fails for a missing file, naming it", %{dir: dir} do
      File.rm!(Path.join(dir, "details.json"))

      error = assert_raise Mix.Error, fn -> Parity.run([dir]) end

      assert error.message =~ "details.json"
    end

    test "says how it is used" do
      assert_raise Mix.Error, ~r/Usage: mix bank.parity RUN_DIR/, fn -> Parity.run([]) end
      assert_raise Mix.Error, ~r/Usage/, fn -> Parity.run(["a", "b"]) end
    end
  end
end
