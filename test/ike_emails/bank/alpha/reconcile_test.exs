defmodule IkeEmails.Bank.Alpha.ReconcileTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Reconcile
  alias IkeEmails.Bank.Alpha.Statements

  # Greek capital Chi (a debit) and Greek capital Pi (a credit), as the bank sends them
  @chi "\u{03A7}"
  @pi "\u{03A0}"

  defp line(amount, sign) do
    %{
      "EntryDate" => "1/1/2026",
      "Valeur" => "1/1/2026",
      "Reason" => "A",
      "Branch" => "99",
      "TransactionUN" => "1",
      "Amount" => amount,
      "AmountSign" => sign
    }
  end

  defp balances(previous, previous_sign, new, new_sign) do
    %{
      "PreviousGrossBalance" => previous,
      "PreviousGrossBalanceSign" => previous_sign,
      "NewGrossBalance" => new,
      "NewGrossBalanceSign" => new_sign
    }
  end

  # The statements as the bank sends them, parsed
  defp parsed(lines, balances) do
    body = Jason.encode!(Map.put(balances, "Statements", lines))
    assert {:ok, parsed} = Statements.parse(body)
    parsed
  end

  describe "check/1" do
    test "is ok when the lines add up to how much the balance moved" do
      lines = [line(90, @chi), line(126.51, @pi), line(1157.98, @pi)]
      balances = balances(100, @pi, 1294.49, @pi)

      assert Reconcile.check(parsed(lines, balances)) == :ok
    end

    test "is a mismatch when the lines add up to something else" do
      lines = [line(90, @chi), line(126.51, @pi)]

      assert Reconcile.check(parsed(lines, balances(100, @pi, 126.51, @pi))) ==
               {:error, :mismatch}

      assert Reconcile.check(parsed(lines, balances(100, @pi, 136.52, @pi))) ==
               {:error, :mismatch}

      assert Reconcile.check(parsed(lines, balances(100, @pi, 136.51, @pi))) == :ok
    end

    test "is a mismatch when a line is missing" do
      lines = [line(126.51, @pi)]

      assert Reconcile.check(parsed(lines, balances(100, @pi, 136.51, @pi))) ==
               {:error, :mismatch}
    end

    test "is a mismatch for a line with the wrong sign" do
      assert Reconcile.check(parsed([line(10, @chi)], balances(100, @pi, 110, @pi))) ==
               {:error, :mismatch}

      assert Reconcile.check(parsed([line(10, @pi)], balances(100, @pi, 90, @pi))) ==
               {:error, :mismatch}
    end

    test "adds the amounts exactly, which floats do not" do
      lines = [line(0.1, @pi), line(0.2, @pi)]

      assert Reconcile.check(parsed(lines, balances(1, @pi, 1.3, @pi))) == :ok
      assert Reconcile.check(parsed(lines, balances(1, @pi, 1.31, @pi))) == {:error, :mismatch}
    end

    test "applies the sign of each balance" do
      # From 100 to -10: the account went into the red
      assert Reconcile.check(parsed([line(110, @chi)], balances(100, @pi, 10, @chi))) == :ok
      # From -50 to 25
      assert Reconcile.check(parsed([line(75, @pi)], balances(50, @chi, 25, @pi))) == :ok
      # From -50 to -20
      assert Reconcile.check(parsed([line(30, @pi)], balances(50, "X", 20, "X"))) == :ok
      # Not the same if the sign of the balance is left out
      assert Reconcile.check(parsed([line(75, @pi)], balances(50, @pi, 25, @pi))) ==
               {:error, :mismatch}

      assert Reconcile.check(parsed([line(25, @chi)], balances(50, @pi, 25, @chi))) ==
               {:error, :mismatch}
    end

    test "is ok for no lines between two equal balances" do
      assert Reconcile.check(parsed([], balances(100.5, @pi, 100.5, @pi))) == :ok
      assert Reconcile.check(parsed([], balances(0, @pi, 0, @chi))) == :ok
      assert Reconcile.check(parsed([], balances(50, @chi, 50, @chi))) == :ok
    end

    test "is a mismatch for no lines between two balances that differ" do
      assert Reconcile.check(parsed([], balances(100, @pi, 101, @pi))) == {:error, :mismatch}
    end

    test "is ok for lines that cancel out" do
      lines = [line(5, @chi), line(5, @pi)]

      assert Reconcile.check(parsed(lines, balances(100, @pi, 100, @pi))) == :ok
    end

    test "refuses when a balance or its sign is null, which the script of the page would skip" do
      lines = [line(90, @chi)]
      complete = balances(100, @pi, 10, @pi)
      assert Reconcile.check(parsed(lines, complete)) == :ok

      for field <- Map.keys(complete) do
        assert Reconcile.check(parsed(lines, Map.put(complete, field, nil))) ==
                 {:error, :balances_missing}

        assert Reconcile.check(parsed(lines, Map.delete(complete, field))) ==
                 {:error, :balances_missing}
      end
    end

    test "refuses when the bank sent no balances at all, even for no lines" do
      assert Reconcile.check(parsed([line(90, @chi)], %{})) == {:error, :balances_missing}
      assert Reconcile.check(parsed([], %{})) == {:error, :balances_missing}
    end

    test "says the balances are missing before it says the lines do not add up" do
      lines = [line(90, @chi)]

      assert Reconcile.check(parsed(lines, balances(100, @pi, nil, nil))) ==
               {:error, :balances_missing}
    end
  end
end
