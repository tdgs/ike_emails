defmodule Mix.Tasks.Bank.ProbeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bank.Probe

  # The whole point is the terminal: another node is started under a pseudo terminal, with
  # the locale that is under test, and a line with characters that are not ASCII is typed
  @pty_skip (fn ->
               python = System.find_executable("python3")

               cond do
                 is_nil(python) ->
                   "needs python3"

                 is_nil(System.find_executable("elixir")) ->
                   "needs elixir on the PATH"

                 true ->
                   try do
                     probe = "import os, pty; os.close(pty.openpty()[0])"

                     case System.cmd(python, ["-I", "-c", probe], stderr_to_stdout: true) do
                       {_output, 0} -> nil
                       _failed -> "python3 has no pty module"
                     end
                   rescue
                     _error -> "python3 cannot be run"
                   end
               end
             end).()

  # Starts the node, waits for the prompt, types the line and gives back what the node
  # printed. The line in the node is shown as hexadecimal, to compare bytes
  @pty_script ~S"""
  import os, pty, select, sys, time

  elixir, ebin, typed_hex, code = sys.argv[1:5]
  env = dict(os.environ)
  for change in sys.argv[5:]:
      if change.startswith("-"):
          env.pop(change[1:], None)
      else:
          name, _, value = change.partition("=")
          env[name] = value

  pid, fd = pty.fork()
  if pid == 0:
      os.execvpe(elixir, [elixir, "-pa", ebin, "-e", code], env)

  out = b""
  sent = False
  timed_out = True
  deadline = time.time() + 40
  while time.time() < deadline:
      ready, _, _ = select.select([fd], [], [], 0.5)
      if not ready:
          continue
      try:
          data = os.read(fd, 4096)
      except OSError:
          timed_out = False
          break
      if not data:
          timed_out = False
          break
      out += data
      if not sent and b"Secret: " in out:
          time.sleep(0.5)
          os.write(fd, bytes.fromhex(typed_hex) + b"\n")
          sent = True

  if timed_out:
      os.kill(pid, 9)
  os.waitpid(pid, 0)
  sys.stdout.buffer.write(out)
  """

  @node_code ~S"""
  before = :io.getopts(:standard_io)[:encoding]
  typed = Mix.Tasks.Bank.Probe.prompt_secret("Secret: ")
  after_ = :io.getopts(:standard_io)[:encoding]
  IO.puts("RESULT:" <> Base.encode16(typed))
  IO.puts("ENCODING:#{before}:#{after_}")
  """

  defp type_in_terminal(typed, locale) do
    python = System.find_executable("python3")
    elixir = System.find_executable("elixir")
    ebin = Mix.Project.compile_path()
    args = ["-I", "-c", @pty_script, elixir, ebin, Base.encode16(typed), @node_code | locale]

    {output, status} = System.cmd(python, args, stderr_to_stdout: true)
    assert status == 0, output
    String.replace(output, "\r", "")
  end

  defp result(output) do
    case Regex.run(~r/RESULT:([0-9A-F]+)/, output) do
      [_all, hex] -> Base.decode16!(hex)
      nil -> flunk("The node printed no result:\n" <> output)
    end
  end

  describe "check_env!/1" do
    test "refuses to run in production" do
      assert_raise Mix.Error, ~r/development/, fn -> Probe.check_env!(:prod) end
    end

    test "runs in development and in the tests" do
      assert Probe.check_env!(:dev) == :ok
      assert Probe.check_env!(:test) == :ok
    end
  end

  describe "parse_args!/1" do
    test "has no option by default" do
      assert Probe.parse_args!([]) == []
    end

    test "reads the options" do
      args = ["--visible", "--profile", "/tmp/profile", "--lang", "el", "--wait", "3"]

      assert Probe.parse_args!(args) == [
               visible: true,
               profile: "/tmp/profile",
               lang: "el",
               wait: 3
             ]
    end

    test "does not take the user name or the password" do
      for args <- [["--username", "x"], ["--password", "x"], ["--iban", "x"], ["something"]] do
        assert_raise Mix.Error, ~r/Usage: mix bank.probe/, fn -> Probe.parse_args!(args) end
      end
    end

    test "takes a number of seconds, 0 or more" do
      assert Probe.parse_args!(["--wait", "0"]) == [wait: 0]

      assert_raise Mix.Error, ~r/Usage/, fn -> Probe.parse_args!(["--wait", "soon"]) end
      assert_raise Mix.Error, ~r/seconds/, fn -> Probe.parse_args!(["--wait", "-1"]) end
    end
  end

  describe "while_logged_in/3" do
    setup do
      me = self()
      {:ok, logout: fn -> send(me, :logged_out) end}
    end

    test "logs out after the work, and returns what the work returned", %{logout: logout} do
      assert Probe.while_logged_in(:ok, logout, fn -> :done end) == :done
      assert_received :logged_out
    end

    test "logs out when the work raises, and the exception goes on", %{logout: logout} do
      assert_raise RuntimeError, "boom", fn ->
        Probe.while_logged_in(:ok, logout, fn -> raise "boom" end)
      end

      assert_received :logged_out
    end

    test "logs out when the work exits or throws", %{logout: logout} do
      assert catch_exit(Probe.while_logged_in(:ok, logout, fn -> exit(:interrupted) end)) ==
               :interrupted

      assert_received :logged_out

      assert catch_throw(Probe.while_logged_in(:ok, logout, fn -> throw(:stop) end)) == :stop
      assert_received :logged_out
    end

    test "does not log out after a login that did not work", %{logout: logout} do
      for result <- [{:error, :bad_credentials}, {:error, :session_in_use}, {:error, :timeout}] do
        assert Probe.while_logged_in(result, logout, fn -> :done end) == :done
      end

      refute_received :logged_out
    end

    test "a logout that fails takes the place neither of the result nor of the exception" do
      failing = fn -> raise "the logout failed" end

      assert Probe.while_logged_in(:ok, failing, fn -> :done end) == :done

      assert_raise RuntimeError, "the work failed", fn ->
        Probe.while_logged_in(:ok, failing, fn -> raise "the work failed" end)
      end

      assert Probe.while_logged_in(:ok, fn -> exit(:gone) end, fn -> :done end) == :done
    end
  end

  describe "prompt_secret/1 in a terminal" do
    @describetag skip: @pty_skip

    @typed "pä-Ωé"

    for {name, locale} <- [
          {"the C locale", ["-LANG", "-LC_CTYPE", "LC_ALL=C"]},
          {"no locale", ["-LANG", "-LC_CTYPE", "-LC_ALL"]},
          {"a UTF-8 locale", ["-LANG", "-LC_CTYPE", "LC_ALL=C.UTF-8"]}
        ] do
      test "reads a line with characters that are not ASCII as it was typed, in #{name}" do
        output = type_in_terminal(@typed, unquote(locale))

        assert result(output) == @typed
        refute output =~ @typed
      end

      test "puts the encoding of the terminal back, in #{name}" do
        output = type_in_terminal(@typed, unquote(locale))

        assert [_all, before, later] = Regex.run(~r/ENCODING:(\w+):(\w+)/, output)
        assert before == later
      end
    end
  end

  describe "lines/2" do
    @snapshot %{
      "path" => "/myAlphaWeb/business/auth/login",
      "forms" => 2,
      "elements" => [
        %{
          "tag" => "input",
          "type" => "text",
          "id" => "user",
          "name" => nil,
          "placeholder" => "Enter your username",
          "aria_label" => nil,
          "classes" => ["form-control", "ng-pristine"],
          # Nothing that is not listed in the module is ever printed
          "value" => "TYPED-VALUE"
        },
        %{"tag" => "button", "type" => nil, "id" => "", "classes" => []}
      ],
      "login_error" => "The user name or the password is wrong"
    }

    test "writes the structure of the page" do
      assert Probe.lines(@snapshot, true) == [
               "  path: /myAlphaWeb/business/auth/login",
               "  forms: 2",
               "  visible inputs, buttons, selects and links: 2",
               ~s|    input type="text" id="user" placeholder="Enter your username" class="form-control ng-pristine"|,
               "    button",
               ~s|  .login-error: "The user name or the password is wrong"|
             ]
    end

    test "lists the messages the page shows, with their text, only with the elements" do
      snapshot =
        Map.put(@snapshot, "alerts", [
          %{"tag" => "mat-error", "classes" => ["mat-mdc-form-field-error"], "text" => "Wrong"},
          %{"tag" => "div", "role" => "alert", "classes" => [], "text" => "Try again"}
        ])

      lines = Probe.lines(snapshot, true)

      assert "  messages shown (alerts, errors):" in lines
      assert ~s|    mat-error class="mat-mdc-form-field-error" text="Wrong"| in lines
      assert ~s|    div role="alert" text="Try again"| in lines

      refute Enum.any?(Probe.lines(snapshot, false), &(&1 =~ "Try again"))
    end

    test "marks an element that is disabled" do
      snapshot = %{
        @snapshot
        | "elements" => [%{"tag" => "button", "type" => "submit", "disabled" => true}]
      }

      assert ~s|    button type="submit" disabled| in Probe.lines(snapshot, true)
    end

    test "writes no element when it is not asked to, but counts them" do
      lines = Probe.lines(@snapshot, false)

      assert length(lines) == 4
      assert "  visible inputs, buttons, selects and links: 2" in lines
    end

    test "says that no error is shown" do
      lines =
        Probe.lines(%{"path" => "/x", "forms" => 0, "elements" => [], "login_error" => nil}, true)

      assert List.last(lines) == "  .login-error: none is shown"
    end

    test "prints no value" do
      assert Probe.lines(@snapshot, true) |> Enum.join("\n") |> String.contains?("TYPED-VALUE") ==
               false
    end
  end

  describe "structure_script/0" do
    test "is one expression that reads no value, cookie or storage" do
      script = Probe.structure_script()

      assert String.starts_with?(script, "(() => {")

      for forbidden <- [
            ".value",
            "cookie",
            "localStorage",
            "sessionStorage",
            "href",
            "location.search"
          ] do
        refute script =~ forbidden
      end
    end
  end

  describe "outcome_message/1" do
    test "says that a timeout is a login that was sent" do
      assert Probe.outcome_message({:error, :timeout}) =~ "The login was sent"
    end

    for reason <- [:no_login_page, :no_login_form, :no_login_button] do
      test "says that nothing was sent for #{reason}" do
        assert Probe.outcome_message({:error, unquote(reason)}) =~ "Nothing was sent"
      end
    end

    test "says nothing more for a result that is already plain" do
      for result <- [:ok, {:error, :bad_credentials}, {:error, :session_in_use}],
          do: assert(Probe.outcome_message(result) == nil)
    end
  end
end
