defmodule IkeEmails.Chrome.ReplyTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Chrome.Reply

  @sentinel "SENTINEL-p4ss-Ωmega"

  defp threw do
    exception = %{
      "type" => "object",
      "subtype" => "error",
      "description" => "Error: " <> @sentinel
    }

    %{
      "result" => exception,
      "exceptionDetails" => %{
        "exceptionId" => 1,
        "text" => "Uncaught " <> @sentinel,
        "lineNumber" => 3,
        "columnNumber" => 7,
        "exception" => exception
      }
    }
  end

  describe "outcome/1" do
    test "returns the result of a reply" do
      assert Reply.outcome(%{"id" => 1, "result" => %{"targetId" => "T"}}) ==
               {:ok, %{"targetId" => "T"}}
    end

    test "returns only the code of a protocol error" do
      reply = %{"id" => 1, "error" => %{"code" => -32_000, "message" => @sentinel}}

      assert Reply.outcome(reply) == {:error, {:cdp_error, -32_000}}
    end

    test "returns that the page is closed when Chrome does not know the session" do
      reply = %{"id" => 1, "error" => %{"code" => -32_001, "message" => "Session with given id"}}

      assert Reply.outcome(reply) == {:error, :page_closed}
    end

    test "returns an error for a reply that is neither" do
      assert Reply.outcome(%{"id" => 1}) == {:error, :bad_reply}
      assert Reply.outcome(%{"id" => 1, "error" => "text"}) == {:error, :cdp_error}
    end

    test "leaves the text of an exception out of the result" do
      assert {:ok, result} = Reply.outcome(%{"id" => 1, "result" => threw()})

      assert result == %{"exceptionDetails" => %{"lineNumber" => 3, "columnNumber" => 7}}
      refute inspect(result) =~ @sentinel
    end
  end

  describe "evaluation/1" do
    test "returns a value" do
      assert Reply.evaluation(%{"result" => %{"type" => "string", "value" => "ok"}}) ==
               {:ok, "ok"}

      assert Reply.evaluation(%{"result" => %{"type" => "boolean", "value" => false}}) ==
               {:ok, false}

      assert Reply.evaluation(%{"result" => %{"type" => "object", "value" => %{"a" => [1]}}}) ==
               {:ok, %{"a" => [1]}}
    end

    test "returns nil for null and for undefined" do
      assert Reply.evaluation(%{"result" => %{"type" => "object", "value" => nil}}) == {:ok, nil}
      assert Reply.evaluation(%{"result" => %{"type" => "undefined"}}) == {:ok, nil}
    end

    test "returns the id of an object that was not returned by value" do
      result = %{"result" => %{"type" => "object", "objectId" => "OBJECT-1"}}

      assert Reply.evaluation(result) == {:ok, %{object_id: "OBJECT-1"}}
    end

    test "returns the place of an exception and nothing else" do
      {:ok, scrubbed} = Reply.outcome(%{"id" => 1, "result" => threw()})

      assert Reply.evaluation(scrubbed) == {:error, {:exception, %{line: 3, column: 7}}}
    end
  end

  describe "navigation/1" do
    test "returns the loader of a navigation to another document" do
      assert Reply.navigation(%{"frameId" => "F", "loaderId" => "L"}) == {:ok, "L"}
    end

    test "returns nil for a navigation that stays in the document" do
      assert Reply.navigation(%{"frameId" => "F"}) == {:ok, nil}
    end

    test "returns the code of the error of Chrome" do
      assert Reply.navigation(%{"errorText" => "net::ERR_CONNECTION_REFUSED"}) ==
               {:error, {:navigation_failed, "net::ERR_CONNECTION_REFUSED"}}
    end

    test "returns no other text" do
      assert Reply.navigation(%{"errorText" => "Cannot navigate to " <> @sentinel}) ==
               {:error, :navigation_failed}
    end
  end
end
