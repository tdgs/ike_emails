defmodule IkeEmails.Bank.Alpha.ScriptTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Script

  # The scripts are those of the crawler written in Gleam, byte for byte. If one is changed on
  # purpose, the hash here is changed with it, in the same commit.
  @sha256 %{
    "login.js" => "168728813b0aa5cd1ef1c3cbd589cba29a89d178e7d816820e80732520a3e485",
    "statements.js" => "cd9cbaf9be2e43cafa9697a36bcf98e805714c48f2519db5ec0b03da864ffc74"
  }

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  describe "the files of the scripts" do
    test "are the ones that were ported, byte for byte" do
      for {file, hash} <- @sha256 do
        assert sha256(File.read!(Path.join("priv/bank", file))) == hash, file
      end
    end
  end

  describe "source/1" do
    test "is the text of the login script" do
      assert Script.source(:login) == File.read!("priv/bank/login.js")
      assert sha256(Script.source(:login)) == @sha256["login.js"]
    end

    test "is the text of the statements script" do
      assert Script.source(:statements) == File.read!("priv/bank/statements.js")
      assert sha256(Script.source(:statements)) == @sha256["statements.js"]
    end

    test "is a function expression that is called as soon as it is evaluated" do
      for name <- [:login, :statements] do
        source = Script.source(name)

        assert is_binary(source)
        assert String.valid?(source)
        assert String.contains?(source, "(() => {")
        assert String.ends_with?(String.trim_trailing(source), "})()")
      end
    end

    test "has the functions the driver calls" do
      login = Script.source(:login)

      for function <- ["find:", "click:", "fill:", "logout:", "leftApp:", "outcome:"],
          do: assert(login =~ function)

      statements = Script.source(:statements)

      for function <- ["fetch:", "fetchDetails:", "listEStatements:", "fetchEStatement:"],
          do: assert(statements =~ function)
    end
  end
end
