defmodule IkeEmails.Chrome.ScriptTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Chrome.Script
  alias IkeEmails.Chrome.Secret

  doctest IkeEmails.Chrome.Script

  defp expression(source, function, args) do
    assert {:ok, iodata} = Script.call(source, function, args)
    IO.iodata_to_binary(iodata)
  end

  describe "call/3" do
    test "calls a function of the script with the arguments as JSON" do
      assert expression("({ f: (x) => x })", "f", %{selector: "input"}) ==
               "(({ f: (x) => x })\n).f({\"selector\":\"input\"})"
    end

    test "starts the call on a new line, so that a comment at the end of the script is closed" do
      assert expression("({ f: () => 1 }) // done", "f", %{}) =~ "// done\n).f({})"
    end

    test "takes the script as iodata" do
      assert expression(["({", ["f: () => 1"], "})"], "f", %{}) == "(({f: () => 1})\n).f({})"
    end

    test "types a Secret as the string it holds" do
      args = %{selector: "#pw", value: Secret.new("p\"w\\Ω")}

      {:ok, iodata} = Script.call("({})", "fill", args)
      arguments = iodata |> IO.iodata_to_binary() |> String.replace_prefix("(({})\n).fill(", "")
      arguments = String.replace_suffix(arguments, ")", "")

      assert Jason.decode!(arguments) == %{"selector" => "#pw", "value" => "p\"w\\Ω"}
    end

    test "types a Secret in a list" do
      assert expression("({})", "f", [Secret.new("a"), %{b: [Secret.new("c")]}]) =~
               ~s|.f(["a",{"b":["c"]}])|
    end

    test "does not accept a function that is not a name" do
      for function <- ["f()", "a.b", "f(); alert(1); g", "", "1f", " f", "f\n", :f, nil] do
        assert Script.call("({})", function, %{}) == {:error, :invalid_function}
      end
    end

    test "accepts the names of JavaScript" do
      for function <- ["f", "_private", "$", "leftApp", "step2"] do
        assert {:ok, _expression} = Script.call("({})", function, %{})
      end
    end

    test "returns an error without the arguments when they are not JSON" do
      sentinel = "SENTINEL-p4ss-Ωmega"

      assert Script.call("({})", "f", %{value: {:tuple, sentinel}}) ==
               {:error, :invalid_arguments}

      assert Script.call("({})", "f", [<<255, 254>>, sentinel]) == {:error, :invalid_arguments}
    end
  end
end
