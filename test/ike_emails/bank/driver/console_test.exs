defmodule IkeEmails.Bank.Driver.ConsoleTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Driver.Console

  doctest IkeEmails.Bank.Driver.Console

  defp event(args), do: %{"type" => "log", "args" => args}
  defp string(value), do: %{"type" => "string", "value" => value}

  describe "line/1" do
    test "keeps a request and the end of a call, with the number of the request" do
      assert Console.line(
               event([string("[crawler]"), string("#12"), string("request"), string("x")])
             ) ==
               {:ok, "#12 request x"}

      assert Console.line(
               event([string("[crawler]"), string("#12"), string("done in"), string("5 ms")])
             ) ==
               {:ok, "#12 done in 5 ms"}
    end

    test "keeps a line that has no number" do
      assert Console.line(event([string("[crawler]"), string("request statements")])) ==
               {:ok, "request statements"}

      assert Console.line(event([string("[crawler]"), string("done in 5 ms")])) ==
               {:ok, "done in 5 ms"}
    end

    test "trims the words, and writes the numbers and the booleans" do
      args = [
        string(" [crawler] "),
        string(" #1 "),
        string("request "),
        %{"type" => "number", "value" => 3},
        %{"type" => "number", "value" => 2.5},
        %{"type" => "boolean", "value" => true}
      ]

      assert Console.line(event(args)) == {:ok, "#1 request 3 2.5 true"}
    end

    test "drops a failure, also when it says the words of a progress line" do
      for words <- [
            ["#1", "failed in", "5 ms", "HTTP 500: {\"a\":1}"],
            ["#1", "failed in", "5 ms", "request"],
            ["#1", "failed in", "done in"],
            ["failed in", "request"]
          ] do
        args = Enum.map(["[crawler]" | words], &string/1)
        assert Console.line(event(args)) == :ignore
      end
    end

    test "drops what is not tagged" do
      assert Console.line(event([string("request"), string("x")])) == :ignore

      assert Console.line(event([string("#1"), string("[crawler]"), string("request")])) ==
               :ignore

      assert Console.line(event([string("[crawler] request")])) == :ignore
      assert Console.line(event([string("[CRAWLER]"), string("request")])) == :ignore
    end

    test "drops a message with an argument that is not a primitive" do
      object = %{"type" => "object", "description" => "Object", "objectId" => "1"}
      null = %{"type" => "object", "subtype" => "null", "value" => nil}

      assert Console.line(event([string("[crawler]"), string("request"), object])) == :ignore
      assert Console.line(event([string("[crawler]"), string("request"), null])) == :ignore
    end

    test "drops the number alone, and other words" do
      assert Console.line(event([string("[crawler]")])) == :ignore
      assert Console.line(event([string("[crawler]"), string("#1")])) == :ignore

      assert Console.line(event([string("[crawler]"), string("#1"), string("statement pdf")])) ==
               :ignore

      assert Console.line(event([string("[crawler]"), string("#x1"), string("request")])) ==
               :ignore
    end

    test "drops what is not an event of the console" do
      assert Console.line(%{}) == :ignore
      assert Console.line(%{"args" => "request"}) == :ignore
    end
  end
end
