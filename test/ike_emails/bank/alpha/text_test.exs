defmodule IkeEmails.Bank.Alpha.TextTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Text

  # Greek capitals are written as escapes where it matters which alphabet a letter is from
  @alpha "\u{0391}"
  @beta "\u{0392}"
  @sigma "\u{03A3}"
  @omega "\u{03A9}"
  @small_alpha "\u{03B1}"
  @accented_alpha "\u{0386}"

  # The Greek capitals that look like a Latin letter, and the Latin letters
  @greek_lookalikes "ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ"
  @latin_lookalikes "ABEZHIKMNOPTYX"

  describe "clean/1 trims" do
    test "the padding the bank adds to a description" do
      assert Text.clean("OPENAI   ") == "OPENAI"
      assert Text.clean("   OPENAI") == "OPENAI"
      assert Text.clean("\t OPENAI \n") == "OPENAI"
    end

    test "all of the Pattern_White_Space at both ends" do
      spaces = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0x200E, 0x200F, 0x2028, 0x2029]

      for space <- spaces do
        text = <<space::utf8>>
        assert Text.clean(text <> "x" <> text) == "x", "U+#{Integer.to_string(space, 16)}"
      end
    end

    test "the left-to-right and right-to-left marks, which String.trim/1 keeps" do
      assert String.trim("\u{200E}x\u{200F}") == "\u{200E}x\u{200F}"
      assert Text.clean("\u{200E}x\u{200F}") == "x"
      assert Text.clean(" \u{200E} x \u{200F} ") == "x"
    end

    test "not the no-break space, the ideographic space or the spaces of U+2000 to U+200A, which String.trim/1 takes off" do
      for space <- [0xA0, 0x1680, 0x3000, 0x202F, 0x205F | Enum.to_list(0x2000..0x200A)] do
        text = <<space::utf8>>
        assert String.trim(text <> "x" <> text) == "x"

        assert Text.clean(text <> "x" <> text) == text <> "x" <> text,
               "U+#{Integer.to_string(space, 16)}"
      end
    end

    test "up to the first character that is not a space" do
      assert Text.clean(" \u{3000} x") == "\u{3000} x"
      assert Text.clean("x \u{3000} ") == "x \u{3000}"
    end

    test "only the ends: the spaces inside stay, however many" do
      assert Text.clean("  A   B  ") == "A   B"
      assert Text.clean("A\u{200E}B") == "A\u{200E}B"
    end

    test "an empty text, or one of only spaces, to an empty text" do
      assert Text.clean("") == ""
      assert Text.clean("    ") == ""
      assert Text.clean(" \u{200E}\u{200F} ") == ""
    end
  end

  describe "clean/1 turns the Greek letters of a Latin word into Latin ones" do
    test "in a word that mixes Greek look-alikes with Latin letters" do
      assert Text.clean("#{@alpha}NTHROPIC") == "ANTHROPIC"
      assert Text.clean("ANTHROPIC#{@alpha}") == "ANTHROPICA"
      assert Text.clean("x#{@beta}") == "xB"
    end

    test "every look-alike, to the letter it looks like" do
      greek = String.codepoints(@greek_lookalikes)
      latin = String.codepoints(@latin_lookalikes)
      assert length(greek) == 14
      assert length(latin) == 14

      for {g, l} <- Enum.zip(greek, latin) do
        assert Text.clean("q" <> g) == "q" <> l
        assert Text.clean(g <> "q") == l <> "q"
      end
    end

    test "the words of a description each on their own" do
      assert Text.clean("ΑΝΤΗRΟΡΙC* CLΑUDΕ SUΒ") == "ANTHROPIC* CLAUDE SUB"
      assert Text.clean("ΕLΟRUS              ") == "ELORUS"
    end

    test "a Greek word is left as it is" do
      assert Text.clean("ΒΕΒΑΙΩΜΕΝΕΣ ΟΦΕΙΛΕΣ") == "ΒΕΒΑΙΩΜΕΝΕΣ ΟΦΕΙΛΕΣ"
    end

    test "a Greek word made only of look-alikes is left as it is: no Latin letter is in it" do
      word = @greek_lookalikes
      assert Text.clean(word) == word
      assert Text.clean(" #{@alpha}#{@beta} ") == "#{@alpha}#{@beta}"
    end

    test "a Latin word is left as it is" do
      assert Text.clean("GITHUB, INC.") == "GITHUB, INC."
      assert Text.clean("Spotify") == "Spotify"
    end

    test "a word with a Greek letter that looks like no Latin one is left as a whole" do
      assert Text.clean("AB#{@sigma}") == "AB#{@sigma}"
      assert Text.clean("#{@alpha}B#{@omega}") == "#{@alpha}B#{@omega}"
      assert Text.clean("#{@sigma}#{@alpha}B") == "#{@sigma}#{@alpha}B"
    end

    test "a word with a lower case Greek letter is left as a whole" do
      assert Text.clean("A#{@small_alpha}") == "A#{@small_alpha}"
      assert Text.clean("#{@alpha}B#{@small_alpha}") == "#{@alpha}B#{@small_alpha}"
    end

    test "a word with an accented Greek capital is left as a whole" do
      assert Text.clean("#{@alpha}B#{@accented_alpha}") == "#{@alpha}B#{@accented_alpha}"
    end

    test "a character of the Greek block that is no letter counts as a Greek letter without a look-alike" do
      assert Text.clean("#{@alpha}B\u{0384}") == "#{@alpha}B\u{0384}"
    end

    test "a digit, a space and a * end a word, so each part is decided on its own" do
      assert Text.clean("#{@alpha}B1#{@sigma}") == "AB1#{@sigma}"
      assert Text.clean("#{@alpha}B #{@sigma}") == "AB #{@sigma}"
      assert Text.clean("#{@alpha}B*#{@sigma}") == "AB*#{@sigma}"
      assert Text.clean("#{@alpha}B-#{@sigma}") == "AB-#{@sigma}"
      assert Text.clean("#{@sigma}#{@alpha}9B") == "#{@sigma}#{@alpha}9B"
    end

    test "a letter that is not of the Latin or the Greek alphabet ends a word as well" do
      assert Text.clean("#{@alpha}B\u{00E9}#{@sigma}") == "AB\u{00E9}#{@sigma}"
    end

    test "nothing else is changed" do
      assert Text.clean("12/34 *~ #{@sigma}") == "12/34 *~ #{@sigma}"
      assert Text.clean("A\nB") == "A\nB"
    end
  end
end
