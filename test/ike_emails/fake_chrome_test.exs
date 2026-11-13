defmodule IkeEmails.FakeChromeTest do
  # It changes the PATH of the node, and the launcher that is remembered
  use ExUnit.Case, async: false

  import Bitwise

  alias IkeEmails.FakeChrome

  @moduletag :tmp_dir

  defp hash(text) do
    :sha256 |> :crypto.hash(text) |> Base.url_encode64(padding: false) |> binary_part(0, 16)
  end

  describe "path/0" do
    test "is a file in the build directory, named by the hash of its text" do
      path = FakeChrome.path()

      assert Path.dirname(path) == Path.join(Mix.Project.build_path(), "fake-chrome")
      assert Path.basename(path) == "chrome-" <> hash(File.read!(path))
    end

    test "runs the script with Python, by their full paths" do
      assert ["#!/bin/sh", exec, ""] = String.split(File.read!(FakeChrome.path()), "\n")

      assert exec =~ ~r|^exec '/[^']+' -I '/[^']+/fake_chrome\.py' "\$@"$|
    end

    test "is executable by the user, and by nobody who is not meant to write it" do
      %File.Stat{mode: mode} = File.stat!(FakeChrome.path())

      assert (mode &&& 0o755) == 0o755
      assert (mode &&& 0o022) == 0
    end

    test "is the same file every time" do
      assert FakeChrome.path() == FakeChrome.path()
    end

    test "says that python3 is needed when there is none", %{tmp_dir: tmp_dir} do
      path = System.get_env("PATH")

      on_exit(fn ->
        System.put_env("PATH", path)
        :persistent_term.erase({FakeChrome, :path})
      end)

      System.put_env("PATH", tmp_dir)
      :persistent_term.erase({FakeChrome, :path})

      error = assert_raise RuntimeError, fn -> FakeChrome.path() end

      assert error.message =~ "python3"
    end
  end

  describe "install_launcher!/2" do
    test "writes the launcher under the name of its hash, once", %{tmp_dir: dir} do
      launcher = "#!/bin/sh\nexec true\n"
      path = FakeChrome.install_launcher!(dir, launcher)

      assert path == Path.join(dir, "chrome-" <> hash(launcher))
      assert File.read!(path) == launcher
      assert FakeChrome.install_launcher!(dir, launcher) == path
      assert File.ls!(dir) == [Path.basename(path)]
    end

    test "gives another text another file", %{tmp_dir: dir} do
      first = FakeChrome.install_launcher!(dir, "#!/bin/sh\nexec '/one/python3'\n")
      second = FakeChrome.install_launcher!(dir, "#!/bin/sh\nexec '/two/python3'\n")

      assert first != second
      assert File.read!(first) =~ "/one/"
      assert File.read!(second) =~ "/two/"
    end

    test "is whole for whoever looks at it, while many write it at once", %{tmp_dir: dir} do
      launcher = "#!/bin/sh\nexec '/some/python3' -I '/some/fake_chrome.py' \"$@\"\n"
      path = Path.join(dir, "chrome-" <> hash(launcher))

      writers =
        for _writer <- 1..16 do
          Task.async(fn -> FakeChrome.install_launcher!(dir, launcher) end)
        end

      readers =
        for _reader <- 1..4 do
          Task.async(fn -> watch(path, launcher, System.monotonic_time(:millisecond) + 5_000) end)
        end

      assert writers |> Task.await_many(:infinity) |> Enum.uniq() == [path]
      assert readers |> Task.await_many(:infinity) |> Enum.all?(&(&1 == :whole))
      assert File.read!(path) == launcher
      assert File.ls!(dir) == [Path.basename(path)]
    end
  end

  # Looks at the file until it has seen it 200 times: every time it is there it has the
  # whole text and the mode to run
  defp watch(path, launcher, deadline, seen \\ 0)

  defp watch(_path, _launcher, _deadline, 200), do: :whole

  defp watch(path, launcher, deadline, seen) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when (mode &&& 0o111) == 0o111 ->
        if File.read(path) == {:ok, launcher},
          do: watch(path, launcher, deadline, seen + 1),
          else: :partial

      {:ok, _not_executable} ->
        :not_executable

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) > deadline,
          do: :never_there,
          else: watch(path, launcher, deadline, seen)
    end
  end
end
