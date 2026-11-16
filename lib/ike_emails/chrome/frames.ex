defmodule IkeEmails.Chrome.Frames do
  @moduledoc """
  The framing of the DevTools protocol over a pipe: every message is a JSON text
  followed by a NUL byte, in both directions.

  What arrives from the pipe is cut anywhere: a message can be split over several
  reads, and one read can hold several messages. `push/2` takes what is left over
  from the last read and the new data, and returns the messages that are complete
  and what is left over now. The left over is a list of the chunks of the message
  that is being read, the last one first, so that a large message (the PDF of a
  statement) is put together once, when it is complete, and not at every read.

  Nothing here looks inside a message, and an empty one (two NULs in a row) is not
  one.
  """

  @type partial :: [binary()]

  @doc "The left over of a pipe that has not been read."
  @spec new() :: partial()
  def new, do: []

  @doc "A message as it is written to the pipe."
  @spec encode(iodata()) :: iodata()
  def encode(json), do: [json, 0]

  @doc """
  The complete messages in `data`, oldest first, and the left over.

      iex> IkeEmails.Chrome.Frames.push([], ~s({"a":1}) <> <<0>> <> ~s({"b))
      {[~s({"a":1})], [~s({"b)]}
  """
  @spec push(partial(), binary()) :: {[binary()], partial()}
  def push(partial, data) do
    case :binary.split(data, <<0>>, [:global]) do
      [chunk] ->
        {[], keep(chunk, partial)}

      [first | rest] ->
        {complete, [last]} = Enum.split(rest, -1)
        frames = Enum.reject([join(keep(first, partial)) | complete], &(&1 == ""))
        {frames, keep(last, [])}
    end
  end

  defp keep("", partial), do: partial
  defp keep(chunk, partial), do: [chunk | partial]

  defp join(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
