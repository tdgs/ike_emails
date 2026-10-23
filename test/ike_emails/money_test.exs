defmodule IkeEmails.MoneyTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Money

  doctest Money

  describe "parse_cents/1" do
    test "reads the formats an amount is typed in" do
      for {input, cents} <- [
            {"12,50", 1250},
            {"12.50", 1250},
            {"12,5", 1250},
            {"12", 1200},
            {"0,99", 99},
            {"1.234,56", 123_456},
            {"1,234.56", 123_456},
            {"1234.56", 123_456},
            {"1.234.567,89", 123_456_789},
            {"1.234", 123_400},
            {"12,505", 1_250_500},
            {" 90,00 € ", 9000},
            {"0", 0}
          ] do
        assert Money.parse_cents(input) == {:ok, cents}, "parsing #{inspect(input)}"
      end
    end

    test "rejects what is not an amount" do
      for input <- ["", "twelve", "-5", "1,2,3", "1.50.00", "12,345,67", "1.234.56", nil] do
        assert Money.parse_cents(input) == :error, "parsing #{inspect(input)}"
      end
    end
  end

  describe "format/2" do
    test "shows euros with a symbol and grouped thousands" do
      assert Money.format(123_456) == "1.234,56 €"
      assert Money.format(5) == "0,05 €"
      assert Money.format(-900) == "-9,00 €"
      assert Money.format(100_000_000) == "1.000.000,00 €"
    end

    test "shows the code of other currencies" do
      assert Money.format(2000, "USD") == "20,00 USD"
    end
  end

  test "format_input/1 round-trips through parse_cents/1" do
    for cents <- [1, 99, 100, 123_456, 100_000_000] do
      assert {:ok, ^cents} = cents |> Money.format_input() |> Money.parse_cents()
    end
  end

  test "cents_from_decimal/1 keeps the sign" do
    assert Money.cents_from_decimal(Decimal.new("-14805.43")) == -1_480_543
    assert Money.cents_from_decimal(Decimal.new("594.40")) == 59_440
  end
end
