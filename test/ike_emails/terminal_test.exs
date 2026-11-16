defmodule IkeEmails.TerminalTest do
  # What is typed in a real terminal is tested through mix bank.probe, see
  # Mix.Tasks.Bank.ProbeTest: it starts a node under a pseudo terminal
  use ExUnit.Case, async: true

  alias IkeEmails.Terminal

  describe "check_shell/1" do
    test "refuses to ask inside iex, where the echo cannot be turned off" do
      assert Terminal.check_shell(true) == {:error, :in_iex}
      assert Terminal.message(:in_iex) =~ "plain shell"
    end

    test "goes on in a plain shell" do
      assert Terminal.check_shell(false) == :ok
    end
  end

  describe "typed/1" do
    test "returns the line without its end of line" do
      assert Terminal.typed("pä-Ωé\n") == {:ok, "pä-Ωé"}
      assert Terminal.typed("pä-Ωé\r\n") == {:ok, "pä-Ωé"}
      assert Terminal.typed("pä-Ωé") == {:ok, "pä-Ωé"}
    end

    test "keeps the spaces, which can be part of a password" do
      assert Terminal.typed("  a b \n") == {:ok, "  a b "}
    end

    test "refuses a line that is not valid UTF-8, without showing it" do
      assert Terminal.typed(<<"abc", 0xE9, "\n">>) == {:error, :not_text}
      assert Terminal.message(:not_text) == "What was typed is not valid UTF-8 text."
    end

    test "refuses an empty line, the end of the input and an error of the device" do
      for line <- ["", "\n", "\r\n", :eof] do
        assert Terminal.typed(line) == {:error, :nothing_typed}
      end

      assert Terminal.typed({:error, :collect_line}) == {:error, :unreadable}
    end
  end

  test "has a message for every error" do
    for reason <- [:in_iex, :no_terminal, :not_text, :unreadable, :nothing_typed] do
      assert is_binary(Terminal.message(reason))
    end
  end
end
