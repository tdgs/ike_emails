defmodule IkeEmails.Bank.SyncTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Crawl
  alias IkeEmails.Bank.Credentials
  alias IkeEmails.Bank.Sync
  alias IkeEmails.BankDriverStub

  # Greek capital Pi (a credit) and Greek capital Chi (a debit), as the bank sends them
  @pi "\u{03A0}"
  @chi "\u{03A7}"

  @iban "GR9999999999999999999999999"
  @credentials %Credentials{username: "sentinel-user", password: "sentinel-password", iban: @iban}
  @pdf "%PDF-1.4\nsynthetic statement\n%%EOF\n"

  # A line of the statements of the bank, a credit of 10 unless `changes` say otherwise
  defp line(id, changes \\ %{}) do
    Map.merge(
      %{
        "EntryDate" => "19/10/2026",
        "Valeur" => "17/10/2026",
        "Reason" => "SHOP #{id}",
        "Branch" => "99",
        "TransactionUN" => id,
        "Amount" => 10,
        "AmountSign" => @pi
      },
      changes
    )
  end

  defp own_detail(sender) do
    %{
      "StatementDetails" => [
        %{"ConversionDetails" => "", "SenderDetails" => sender, "AdditionalInformation" => ""}
      ]
    }
  end

  # The body of the statements, with balances that agree with the lines unless `response`
  # says otherwise
  defp statements_body(lines, response \\ %{}) do
    added =
      lines
      |> Enum.map(fn %{"Amount" => amount, "AmountSign" => sign} ->
        if sign == @pi, do: amount, else: -amount
      end)
      |> Enum.sum()

    %{
      "Statements" => lines,
      "PreviousGrossBalance" => 1000,
      "PreviousGrossBalanceSign" => @pi,
      "NewGrossBalance" => 1000 + added,
      "NewGrossBalanceSign" => @pi
    }
    |> Map.merge(response)
    |> Jason.encode!()
  end

  defp estatements_body(estatements) do
    Jason.encode!(%{
      "ResultCode" => 0,
      "EStatements" =>
        for {id, date_from, date_to} <- estatements do
          %{
            "EStatementIssued" => true,
            "EstatementID" => id,
            "DateFrom" => date_from,
            "DateTo" => date_to,
            "IssuedDate" => "2026-10-02"
          }
        end
    })
  end

  defp pdf_answer(pdf \\ @pdf), do: {:ok, %{bytes: byte_size(pdf), base64: Base.encode64(pdf)}}

  # The answers for the statements of `lines`, and others on top
  defp readable(lines, answers \\ %{}) do
    Map.put(answers, :fetch_statements, {:ok, statements_body(lines)})
  end

  defp run(answers, opts \\ []) do
    test = self()
    BankDriverStub.script(answers)

    opts = Keyword.merge([driver: BankDriverStub, sleep: &send(test, {:slept, &1})], opts)
    Sync.crawl(@credentials, opts)
  end

  defp calls(calls \\ []) do
    receive do
      {:driver_call, operation, args} -> calls([{operation, args} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp operations, do: Enum.map(calls(), fn {operation, _args} -> operation end)

  defp sleeps(sleeps \\ []) do
    receive do
      {:slept, milliseconds} -> sleeps([milliseconds | sleeps])
    after
      0 -> Enum.reverse(sleeps)
    end
  end

  defp ids(rows), do: Enum.map(rows, & &1.transaction_id)

  describe "crawl/2" do
    test "reads the rows and the latest statement, in the order of the calls" do
      lines = [
        line("1"),
        line("2", %{"Amount" => 5, "AmountSign" => @chi}),
        line("3", own_detail("OWN 3"))
      ]

      answers =
        readable(lines, %{
          list_estatements:
            {:ok,
             estatements_body([
               {"AAA", "2026-08-01", "2026-08-31"},
               {"BBB", "2026-09-01", "2026-09-30"}
             ])},
          fetch_estatement: pdf_answer()
        })

      assert {:ok, %Crawl{} = crawl} = run(answers)

      assert Enum.map(crawl.rows, &{&1.transaction_id, &1.date, &1.amount, &1.sender_details}) ==
               [
                 {"1", "2026-10-19", "10.00", "SENDER 1"},
                 {"2", "2026-10-19", "-5.00", "SENDER 2"},
                 {"3", "2026-10-19", "10.00", "OWN 3"}
               ]

      assert crawl.statement == %{
               month: "2026-09",
               file_name: "estatement-2026-09.pdf",
               pdf: @pdf
             }

      assert {crawl.details_failed, crawl.skipped, crawl.rejected, crawl.stopped} ==
               {0, [], [], nil}

      assert Crawl.complete?(crawl)

      # The details are asked for only where the line lists none of its own
      assert calls() == [
               {:open, [[]]},
               {:login, [:credentials]},
               {:fetch_statements, [:iban, 365]},
               {:fetch_details, [:iban, ["1", "2"]]},
               {:list_estatements, [:iban]},
               {:fetch_estatement, ["BBB"]},
               {:logout, []},
               {:close, []}
             ]

      assert sleeps() == []
    end

    test "reads the days it is given, for the IBAN of the credentials" do
      answers = %{fetch_statements: fn [@iban, 30] -> {:ok, statements_body([])} end}

      assert {:ok, %Crawl{rows: []}} = run(answers, days: 30)
      assert {:fetch_statements, [:iban, 30]} in calls()
    end

    test "hands the options of the driver to open" do
      assert {:ok, %Crawl{}} = run(readable([]), driver_opts: [profile: "somewhere"])
      assert {:open, [[profile: "somewhere"]]} in calls()
    end

    test "uses the driver of the configuration when it is given none" do
      BankDriverStub.script(readable([]))

      assert {:ok, %Crawl{rows: []}} = Sync.crawl(@credentials)
      assert [{:open, [[]]}, {:login, _} | _rest] = calls()
    end

    test "returns an error when the driver cannot be opened, and has nothing to close" do
      assert run(%{open: {:error, :no_browser}}) == {:error, {:open, :no_browser}}
      assert calls() == [{:open, [[]]}]
    end
  end

  describe "the login" do
    test "logs in again after waiting 2 seconds when the session is in use" do
      session_in_use = {:error, :session_in_use}
      answers = readable([line("1")], %{login: [session_in_use, session_in_use, :ok]})

      assert {:ok, %Crawl{rows: [_row]}} = run(answers)

      assert sleeps() == [2000, 2000]

      assert operations() ==
               [:open, :login, :login, :login, :fetch_statements] ++
                 [:fetch_details, :list_estatements, :logout, :close]
    end

    test "gives up when the session is in use at the third attempt, without waiting again" do
      answers = readable([line("1")], %{login: {:error, :session_in_use}})

      assert run(answers) == {:error, {:login, :session_in_use}}

      assert sleeps() == [2000, 2000]
      assert operations() == [:open, :login, :login, :login, :close]
    end

    test "does not try again after any other refusal, nor log out" do
      for reason <- [:bad_credentials, {:challenge, :sms}, :timeout, :unknown] do
        answers = readable([line("1")], %{login: {:error, reason}})

        assert run(answers) == {:error, {:login, reason}}

        assert sleeps() == []
        assert operations() == [:open, :login, :close]
      end
    end

    test "does not try again after a refusal that follows a session in use" do
      answers = %{login: [{:error, :session_in_use}, {:error, :bad_credentials}]}

      assert run(answers) == {:error, {:login, :bad_credentials}}

      assert sleeps() == [2000]
      assert operations() == [:open, :login, :login, :close]
    end
  end

  describe "the statements" do
    test "are refused when they do not add up to the balances, and no details are asked for" do
      body = statements_body([line("1")], %{"NewGrossBalance" => 1})

      assert run(%{fetch_statements: {:ok, body}}) == {:error, {:statements, :mismatch}}

      assert operations() == [:open, :login, :fetch_statements, :logout, :close]
    end

    test "are refused when the bank sends no balance" do
      body = statements_body([line("1")], %{"NewGrossBalance" => nil})

      assert run(%{fetch_statements: {:ok, body}}) == {:error, {:statements, :balances_missing}}
    end

    test "are refused when they cannot be read" do
      assert run(%{fetch_statements: {:ok, "not json"}}) ==
               {:error, {:statements, :unexpected_response}}
    end

    test "are refused for the reason of the driver, and the session is ended" do
      assert run(%{fetch_statements: {:error, :timeout}}) == {:error, {:statements, :timeout}}

      assert operations() == [:open, :login, :fetch_statements, :logout, :close]
    end
  end

  describe "the details" do
    test "are asked for in batches of 20, in the order of the statements" do
      ids = for number <- 1..45, do: Integer.to_string(number)

      assert {:ok, %Crawl{rows: rows, details_failed: 0}} = run(readable(Enum.map(ids, &line/1)))

      assert ids(rows) == ids
      assert Enum.all?(rows, &(&1.sender_details == "SENDER " <> &1.transaction_id))

      batches = for {:fetch_details, [:iban, batch]} <- calls(), do: batch
      assert batches == Enum.chunk_every(ids, 20)
    end

    test "are asked for once for a transaction that has several lines" do
      lines = [line("1"), line("1", %{"Amount" => 20}), line("2")]

      assert {:ok, %Crawl{rows: rows}} = run(readable(lines))

      assert ids(rows) == ["1", "1", "2"]
      assert {:fetch_details, [:iban, ["1", "2"]]} in calls()
    end

    test "are not asked for when every line lists its own" do
      lines = [line("1", own_detail("OWN 1")), line("2", own_detail("OWN 2"))]

      assert {:ok, %Crawl{rows: [_, _]}} = run(readable(lines))

      assert :fetch_details not in operations()
    end

    test "leave out the rows of the transactions that the bank gave none for" do
      lines = Enum.map(["1", "2", "3", "4"], &line/1)

      answers =
        readable(lines, %{fetch_details: BankDriverStub.details(~w(1 2 3 4), failed: ~w(2 4))})

      assert {:ok, %Crawl{} = crawl} = run(answers)

      assert ids(crawl.rows) == ["1", "3"]
      assert crawl.skipped == ["2", "4"]
      assert crawl.details_failed == 2
      assert crawl.stopped == nil

      # Not being stopped, it goes on to the statement
      assert :list_estatements in operations()
    end

    test "leave out only the lines that have no detail of their own" do
      lines = [line("1"), line("1", Map.merge(%{"Amount" => 20}, own_detail("OWN 1")))]
      answers = readable(lines, %{fetch_details: BankDriverStub.details(["1"], failed: ["1"])})

      assert {:ok, %Crawl{rows: [row], skipped: ["1"], details_failed: 1}} = run(answers)

      assert {row.amount, row.sender_details} == {"20.00", "OWN 1"}
    end

    test "stop being asked for when the bank refuses, and what was read is returned" do
      ids = for number <- 1..45, do: Integer.to_string(number)
      [first, second, _third] = Enum.chunk_every(ids, 20)
      lines = Enum.map(ids, &line/1) ++ [line("46", own_detail("OWN 46"))]

      for status <- [401, 403] do
        answers =
          readable(lines, %{
            fetch_details: [
              BankDriverStub.details(first),
              BankDriverStub.details(Enum.take(second, 5), stopped: status)
            ],
            fetch_estatement: pdf_answer()
          })

        assert {:ok, %Crawl{} = crawl} = run(answers)

        assert ids(crawl.rows) == Enum.take(ids, 25) ++ ["46"]
        assert crawl.skipped == Enum.drop(ids, 25)
        assert crawl.details_failed == 20
        assert crawl.stopped == status
        assert crawl.statement == nil
        refute Crawl.complete?(crawl)

        # The third batch is not asked for, nor is the statement, and the session is ended
        assert operations() ==
                 [:open, :login, :fetch_statements, :fetch_details, :fetch_details] ++
                   [:logout, :close]
      end
    end

    test "are refused for the reason of the driver when a batch fails, and nothing is returned" do
      ids = for number <- 1..45, do: Integer.to_string(number)
      [first, _second, _third] = Enum.chunk_every(ids, 20)

      answers =
        readable(Enum.map(ids, &line/1), %{
          fetch_details: [BankDriverStub.details(first), {:error, :timeout}]
        })

      assert run(answers) == {:error, {:details, :timeout}}

      assert operations() ==
               [:open, :login, :fetch_statements, :fetch_details, :fetch_details] ++
                 [:logout, :close]
    end

    test "are refused when an answer of the bank cannot be read" do
      unreadable = {:ok, %{entries: [%{id: "1", json: "not json"}], failed: 0, stopped: nil}}

      assert run(readable([line("1")], %{fetch_details: unreadable})) ==
               {:error, {:details, :unexpected_response}}

      assert List.last(calls()) == {:close, []}
    end
  end

  describe "the rows" do
    test "leave out a line whose date cannot be read, say which, and go on to the statement" do
      lines = [
        line("1"),
        line("2", %{"EntryDate" => "31/02/2026"}),
        line("3", %{"Valeur" => "17/10/2026 12:00:00"}),
        line("4", own_detail("OWN 4"))
      ]

      answers =
        readable(lines, %{
          list_estatements: {:ok, estatements_body([{"AAA", "2026-09-01", "2026-09-30"}])},
          fetch_estatement: pdf_answer()
        })

      assert {:ok, %Crawl{} = crawl} = run(answers)

      assert ids(crawl.rows) == ["1", "4"]
      assert crawl.rejected == ["2", "3"]
      assert {crawl.details_failed, crawl.skipped, crawl.stopped} == {0, [], nil}

      assert crawl.statement == %{
               month: "2026-09",
               file_name: "estatement-2026-09.pdf",
               pdf: @pdf
             }

      assert Crawl.complete?(crawl)

      # Their details are asked for like the others, and the session is ended as always
      assert operations() ==
               [:open, :login, :fetch_statements, :fetch_details] ++
                 [:list_estatements, :fetch_estatement, :logout, :close]
    end

    test "say a line once for each time it is rejected, when lines share an id" do
      lines = [
        line("1", %{"EntryDate" => "x"}),
        line("1", %{"Amount" => 20}),
        line("1", %{"Valeur" => "y"})
      ]

      assert {:ok, %Crawl{rows: [row], rejected: ["1", "1"]}} = run(readable(lines))
      assert row.amount == "20.00"
    end

    test "are all left out, with no error, when every date cannot be read" do
      lines = [line("1", %{"EntryDate" => "x"}), line("2", %{"EntryDate" => "y"})]

      assert {:ok, %Crawl{rows: [], rejected: ["1", "2"], stopped: nil}} = run(readable(lines))
    end

    test "do not count a rejected line as a failure of the details" do
      lines = [line("1", %{"EntryDate" => "x"}), line("2")]

      assert {:ok, %Crawl{} = crawl} = run(readable(lines))

      assert {crawl.rejected, crawl.skipped, crawl.details_failed} == {["1"], [], 0}
    end

    test "leave a line whose details are missing in skipped, not in rejected, even with a bad date" do
      lines = [line("1", %{"EntryDate" => "x"}), line("2", %{"EntryDate" => "y"}), line("3")]

      answers =
        readable(lines, %{fetch_details: BankDriverStub.details(~w(1 2 3), failed: ["1"])})

      assert {:ok, %Crawl{} = crawl} = run(answers)

      assert ids(crawl.rows) == ["3"]
      assert crawl.skipped == ["1"]
      assert crawl.details_failed == 1
      assert crawl.rejected == ["2"]
    end

    test "leave out a rejected line also when the bank stopped the crawl" do
      lines = [line("1", %{"EntryDate" => "x"}), line("2")]

      answers = readable(lines, %{fetch_details: BankDriverStub.details(["1"], stopped: 403)})

      assert {:ok, %Crawl{} = crawl} = run(answers)

      assert ids(crawl.rows) == []
      assert crawl.skipped == ["2"]
      assert crawl.rejected == ["1"]
      assert crawl.statement == nil
      refute Crawl.complete?(crawl)
    end

    test "have nothing of the dates in the result" do
      lines = [line("1", %{"EntryDate" => "31/02/2026", "Valeur" => "SECRET-DATE"})]

      assert {:ok, %Crawl{} = crawl} = run(readable(lines))

      assert crawl.rejected == ["1"]
      refute inspect(crawl) =~ "SECRET-DATE"
      refute inspect(crawl) =~ "31/02"
    end
  end

  describe "the statement" do
    test "is nil, and the rows are returned, when there is none or it cannot be read" do
      list = {:ok, estatements_body([{"AAA", "2026-09-01", "2026-09-30"}])}

      cases = %{
        "the bank has issued none" => %{list_estatements: {:ok, estatements_body([])}},
        "the list cannot be fetched" => %{list_estatements: {:error, :timeout}},
        "the list cannot be read" => %{list_estatements: {:ok, "not json"}},
        "the PDF cannot be fetched" => %{
          list_estatements: list,
          fetch_estatement: {:error, :timeout}
        },
        "the PDF is cut short" => %{
          list_estatements: list,
          fetch_estatement: {:ok, %{bytes: byte_size(@pdf) + 1, base64: Base.encode64(@pdf)}}
        },
        "the PDF is not one" => %{
          list_estatements: list,
          fetch_estatement: pdf_answer("<html>session ended</html>")
        }
      }

      for {why, extra} <- cases do
        result = run(readable([line("1")], extra))

        assert {:ok, %Crawl{statement: nil, skipped: [], stopped: nil} = crawl} = result, why
        assert ids(crawl.rows) == ["1"]
        assert List.last(calls()) == {:close, []}
      end
    end
  end

  describe "when something goes wrong in the driver" do
    setup do
      answers =
        readable([line("1")], %{
          list_estatements: {:ok, estatements_body([{"AAA", "2026-09-01", "2026-09-30"}])},
          fetch_estatement: pdf_answer()
        })

      %{answers: answers}
    end

    test "logs out and closes when it raises, and raises again", %{answers: answers} do
      for operation <- [:fetch_statements, :fetch_details, :list_estatements, :fetch_estatement] do
        raising = Map.put(answers, operation, fn _args -> raise "boom" end)

        assert_raise RuntimeError, "boom", fn -> run(raising) end

        operations = operations()
        assert operation in operations
        assert Enum.take(operations, -2) == [:logout, :close]
      end
    end

    test "closes, but has no session to end, when it raises at the login", %{answers: answers} do
      assert_raise RuntimeError, "boom", fn ->
        run(Map.put(answers, :login, fn _args -> raise "boom" end))
      end

      assert operations() == [:open, :login, :close]
    end

    test "gives the result even when the logout or the close fail", %{answers: answers} do
      failures = [
        {:logout, {:error, :timeout}},
        {:logout, fn _args -> raise "no logout" end},
        {:logout, fn _args -> exit(:no_logout) end},
        {:close, fn _args -> raise "no close" end}
      ]

      for {operation, failure} <- failures do
        assert {:ok, %Crawl{rows: [_row], statement: %{month: "2026-09"}}} =
                 run(Map.put(answers, operation, failure))

        assert Enum.take(operations(), -2) == [:logout, :close]
      end
    end

    test "raises what went wrong in the crawl, not what went wrong in the logout", %{
      answers: answers
    } do
      failing =
        answers
        |> Map.put(:fetch_statements, fn _args -> raise "boom" end)
        |> Map.put(:logout, fn _args -> raise "no logout" end)

      assert_raise RuntimeError, "boom", fn -> run(failing) end

      assert Enum.take(operations(), -2) == [:logout, :close]
    end
  end

  describe "the credentials" do
    test "are not in the messages of the driver, nor in the results" do
      lines = [line("1")]

      scenarios = [
        readable(lines),
        %{login: {:error, :bad_credentials}},
        %{login: {:error, {:challenge, :sms}}},
        %{fetch_statements: {:ok, statements_body(lines, %{"NewGrossBalance" => 1})}},
        readable(lines, %{fetch_details: {:error, :timeout}}),
        readable([line("1", %{"EntryDate" => "31/02/2026"})]),
        readable(lines, %{fetch_details: BankDriverStub.details(["1"], stopped: 403)})
      ]

      for answers <- scenarios do
        seen = inspect({run(answers), calls()})

        for secret <- [@credentials.username, @credentials.password, @iban] do
          refute seen =~ secret
        end
      end
    end
  end
end
