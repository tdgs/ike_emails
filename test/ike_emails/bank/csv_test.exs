defmodule IkeEmails.Bank.CsvTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Csv

  doctest IkeEmails.Bank.Csv

  describe "parse/1" do
    test "reads the records and the fields" do
      assert Csv.parse("a,b,c\n1,2,3\n") == {:ok, [["a", "b", "c"], ["1", "2", "3"]]}
    end

    test "reads a file that does not end with a line break" do
      assert Csv.parse("a,b\n1,2") == {:ok, [["a", "b"], ["1", "2"]]}
    end

    test "reads records that end with a carriage return and a line feed" do
      assert Csv.parse("a,b\r\n1,2\r\n") == {:ok, [["a", "b"], ["1", "2"]]}
    end

    test "reads no record in nothing" do
      assert Csv.parse("") == {:ok, []}
    end

    test "reads empty fields, also at the start and at the end of a record" do
      assert Csv.parse(",a,,\n,,\n") == {:ok, [["", "a", "", ""], ["", "", ""]]}
      assert Csv.parse("a,") == {:ok, [["a", ""]]}
    end

    test "reads a field in quotes that has a comma, a quote and a line break" do
      assert Csv.parse(~s("a, b","say ""hi""","one\ntwo"\n)) ==
               {:ok, [["a, b", ~s(say "hi"), "one\ntwo"]]}
    end

    test "reads a field in quotes that has a carriage return and a line feed" do
      assert Csv.parse("\"one\r\ntwo\",x\r\n") == {:ok, [["one\r\ntwo", "x"]]}
    end

    test "reads a field of only a quote, and an empty one in quotes" do
      assert Csv.parse(~s("""",""\n)) == {:ok, [[~s("), ""]]}
    end

    test "reads text that is not ASCII" do
      assert Csv.parse("ΑΝΤΗ,\"ΜΑΡΙΑ, Ν\"\n") == {:ok, [["ΑΝΤΗ", "ΜΑΡΙΑ, Ν"]]}
    end

    test "reads a blank line as a record of one empty field" do
      assert Csv.parse("a\n\nb\n") == {:ok, [["a"], [""], ["b"]]}
    end

    test "reads a file with a byte order mark at the start as if it had none" do
      assert Csv.parse("\uFEFFa,b\n1,2\n") == {:ok, [["a", "b"], ["1", "2"]]}
      assert Csv.parse("\uFEFF\"a\",b\r\n1,2\r\n") == {:ok, [["a", "b"], ["1", "2"]]}
      assert Csv.parse("\uFEFF") == {:ok, []}
    end

    test "takes the byte order mark only at the start, and only once" do
      assert Csv.parse("a,\uFEFFb\n") == {:ok, [["a", "\uFEFFb"]]}
      assert Csv.parse("\uFEFF\uFEFFa\n") == {:ok, [["\uFEFFa"]]}
    end

    test "reads no record in blank lines at the end, however many" do
      assert Csv.parse("a,b\n1,2\n\n") == {:ok, [["a", "b"], ["1", "2"]]}
      assert Csv.parse("a,b\n1,2\n\n\n\n") == {:ok, [["a", "b"], ["1", "2"]]}
      assert Csv.parse("a,b\r\n1,2\r\n\r\n\r\n") == {:ok, [["a", "b"], ["1", "2"]]}
      assert Csv.parse("a,b\n1,2\r\n\n\r\n") == {:ok, [["a", "b"], ["1", "2"]]}
      assert Csv.parse("a,b\n1,2") == {:ok, [["a", "b"], ["1", "2"]]}
      assert Csv.parse("\n\n") == {:ok, []}
    end

    test "reads a blank line that is not at the end as a record, and keeps a record that is empty" do
      assert Csv.parse("a\n\n\nb\n\n") == {:ok, [["a"], [""], [""], ["b"]]}
      assert Csv.parse("a,b\n,\n\n") == {:ok, [["a", "b"], ["", ""]]}
      assert Csv.parse("a\n\"\"\n\n") == {:ok, [["a"], [""]]}
    end

    test "reads records that end with a carriage return and a line feed, in every kind of field" do
      text = "a,\"b\"\r\n1,\r\n\"x, y\",\"z\"\r\n,\"\"\r\n"

      assert Csv.parse(text) ==
               {:ok, [["a", "b"], ["1", ""], ["x, y", "z"], ["", ""]]}

      assert Csv.parse(String.trim_trailing(text, "\r\n")) ==
               {:ok, [["a", "b"], ["1", ""], ["x, y", "z"], ["", ""]]}
    end

    test "keeps a carriage return and a line feed inside a field in quotes, with the rest saved again" do
      text = "\uFEFFa,b\r\n\"one\r\ntwo\",\"three\nfour\"\r\n\r\n"

      assert Csv.parse(text) == {:ok, [["a", "b"], ["one\r\ntwo", "three\nfour"]]}
    end

    test "still refuses a quote in a field that does not start with one" do
      assert Csv.parse(~s(a"b,c\n)) == {:error, :malformed}
    end

    test "refuses text after the closing quote" do
      assert Csv.parse(~s("a"b,c\n)) == {:error, :malformed}
    end

    test "refuses a quote that is never closed" do
      assert Csv.parse(~s(a,"b\nc\n)) == {:error, :unterminated_quote}
    end
  end
end
