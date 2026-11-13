defmodule IkeEmails.Chrome.FramesTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Chrome.Frames

  doctest IkeEmails.Chrome.Frames

  describe "push/2" do
    test "returns a message that arrived whole" do
      assert {[~s({"id":1})], []} = Frames.push(Frames.new(), ~s({"id":1}) <> <<0>>)
    end

    test "keeps a message that has not ended until the rest arrives" do
      {frames, partial} = Frames.push(Frames.new(), ~s({"id":))
      assert frames == []

      {frames, partial} = Frames.push(partial, ~s(1,"res))
      assert frames == []

      assert {[~s({"id":1,"result":{}})], []} = Frames.push(partial, ~s(ult":{}}) <> <<0>>)
    end

    test "splits several messages that arrived together" do
      data = ~s({"id":1}) <> <<0>> <> ~s({"id":2}) <> <<0>> <> ~s({"id":3}) <> <<0>>

      assert {[~s({"id":1}), ~s({"id":2}), ~s({"id":3})], []} = Frames.push([], data)
    end

    test "keeps the start of a message that follows complete ones" do
      data = ~s({"id":1}) <> <<0>> <> ~s({"id":2})

      {frames, partial} = Frames.push([], data)
      assert frames == [~s({"id":1})]

      assert {[~s({"id":2})], []} = Frames.push(partial, <<0>>)
    end

    test "ends a message with a NUL that arrives alone" do
      {[], partial} = Frames.push([], "abc")

      assert {["abc"], []} = Frames.push(partial, <<0>>)
    end

    test "ignores empty messages" do
      assert {[], []} = Frames.push([], <<0, 0, 0>>)
      assert {[], []} = Frames.push([], "")
      assert {["a", "b"], []} = Frames.push([], <<0>> <> "a" <> <<0, 0>> <> "b" <> <<0>>)
    end

    test "cuts a stream at any place into the same messages" do
      stream = for id <- 1..5, into: "", do: ~s({"id":#{id},"text":"Ωmega ✓"}) <> <<0>>
      expected = for id <- 1..5, do: ~s({"id":#{id},"text":"Ωmega ✓"})

      # Even inside a character of more than one byte
      for size <- [1, 2, 3, 7, 16, byte_size(stream)] do
        {frames, partial} =
          stream
          |> chunks(size)
          |> Enum.reduce({[], Frames.new()}, fn chunk, {frames, partial} ->
            {complete, partial} = Frames.push(partial, chunk)
            {frames ++ complete, partial}
          end)

        assert frames == expected, "chunks of #{size} bytes"
        assert partial == []
      end
    end

    test "puts a large message together from many reads" do
      body = String.duplicate("x", 1_000_000)
      message = ~s({"data":"#{body}"})

      {frames, partial} =
        (message <> <<0>>)
        |> chunks(65_536)
        |> Enum.reduce({[], Frames.new()}, fn chunk, {frames, partial} ->
          {complete, partial} = Frames.push(partial, chunk)
          {frames ++ complete, partial}
        end)

      assert length(frames) == 1
      assert hd(frames) == message
      assert partial == []
    end
  end

  describe "encode/1" do
    test "ends the message with a NUL" do
      assert IO.iodata_to_binary(Frames.encode(["{", ~s("id":1), "}"])) == ~s({"id":1}) <> <<0>>
    end
  end

  defp chunks(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunks(binary, size) do
    <<chunk::binary-size(size), rest::binary>> = binary
    [chunk | chunks(rest, size)]
  end
end
