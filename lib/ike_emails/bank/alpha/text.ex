defmodule IkeEmails.Bank.Alpha.Text do
  @moduledoc """
  Cleans the texts of the bank before they are stored: the description of a transaction
  and the three texts of its details. The branch and the transaction id are not cleaned.

  The bank pads descriptions with spaces, and writes Latin words with Greek capitals that
  look the same, such as a Greek Alpha (U+0391) in the middle of `ANTHROPIC`. The same
  merchant would then be stored twice under two descriptions that look the same, so
  `clean/1` does two things:

    1. It trims the text.
    2. It turns the Greek letters of a word into their Latin look-alikes, when the word
       has Latin letters as well, and every Greek letter it has is one that looks like a
       Latin one (the capitals `ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ`, which become `ABEZHIKMNOPTYX`).

  A word is a run of the letters `A-Z`, `a-z` and the Greek block (U+0370 to U+03FF).
  Anything else ends a word: a digit, a space, a `*`, a Latin letter with an accent.
  So a Greek word is left alone, and so is a Latin one; and a word that has a lower case
  Greek letter, a capital without a look-alike (such as Sigma or Omega) or a Greek
  letter with an accent is left alone as a whole, its look-alikes included. Nothing that
  is not a letter of a word is changed.

  The result is part of the key by which a stored transaction is found again
  (`user_id`, `transaction_id`, `amount` and `description`), so it has to be the same as
  that of the crawler written in Gleam that this was ported from, character for
  character, or every transaction that was stored would be stored a second time. That is
  why this module does not use what Elixir has for the same jobs:

    * `String.trim/1` takes off the Unicode `White_Space`, which has the no-break space
      (U+00A0), the ideographic space (U+3000) and the spaces of U+2000 to U+200A, but
      not the left-to-right and right-to-left marks (U+200E and U+200F). The trim of
      Gleam takes off the `Pattern_White_Space`: tab, line feed, vertical tab, form
      feed, carriage return, space, U+0085, U+200E, U+200F, U+2028 and U+2029, and
      nothing else. Here it is done by code point, not by grapheme: a space followed by a
      combining mark is trimmed.
    * A character is Greek when its code point is in the Greek block, whether or not it is
      a letter (the tonos, U+0384, is one). Such a character has no look-alike, so it
      keeps the word as it is, as a lower case letter does.
  """

  # The Pattern_White_Space
  @spaces [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0x200E, 0x200F, 0x2028, 0x2029]

  # The Greek capitals that look like a Latin letter, and that letter:
  # Alpha, Beta, Epsilon, Zeta, Eta, Iota, Kappa, Mu, Nu, Omicron, Rho, Tau, Upsilon, Chi
  @lookalikes %{
    0x0391 => ?A,
    0x0392 => ?B,
    0x0395 => ?E,
    0x0396 => ?Z,
    0x0397 => ?H,
    0x0399 => ?I,
    0x039A => ?K,
    0x039C => ?M,
    0x039D => ?N,
    0x039F => ?O,
    0x03A1 => ?P,
    0x03A4 => ?T,
    0x03A5 => ?Y,
    0x03A7 => ?X
  }

  @doc """
  The text trimmed, with the Greek letters of the words that are Latin turned into Latin
  ones. See the module for what a word is and which letters are turned.

  An empty text, or one of only spaces, is cleaned to an empty text.
  """
  @spec clean(String.t()) :: String.t()
  def clean(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> trim()
    |> Enum.chunk_by(&letter?/1)
    |> Enum.flat_map(&latinise/1)
    |> List.to_string()
  end

  defp trim(codepoints) do
    codepoints
    |> Enum.drop_while(&space?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&space?/1)
    |> Enum.reverse()
  end

  defp space?(codepoint), do: codepoint in @spaces

  defp letter?(codepoint), do: latin?(codepoint) or greek?(codepoint)

  defp latin?(codepoint), do: codepoint in ?A..?Z or codepoint in ?a..?z

  defp greek?(codepoint), do: codepoint in 0x0370..0x03FF

  defp latinise(word) do
    greek = Enum.filter(word, &greek?/1)

    if Enum.any?(word, &latin?/1) and greek != [] and
         Enum.all?(greek, &Map.has_key?(@lookalikes, &1)) do
      Enum.map(word, &Map.get(@lookalikes, &1, &1))
    else
      word
    end
  end
end
