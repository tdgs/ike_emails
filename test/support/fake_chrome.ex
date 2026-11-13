defmodule IkeEmails.FakeChrome do
  @moduledoc """
  A stand-in for Chrome, to start `IkeEmails.Chrome` in the tests without one. It is a
  Python script (`test/support/fake_chrome.py`, which says what it answers) that reads
  the commands from file descriptor 3 and writes to file descriptor 4, as Chrome does
  with `--remote-debugging-pipe`.

  The default `mix test` needs `python3` on the `PATH`, and a `kill` executable (for
  `alive?/1`). Without `python3` the tests that start the fake stop with a message that says
  so, instead of a Chrome that exits at once.

  `IkeEmails.Chrome` starts a program through `env -i`, and a script with
  `#!/usr/bin/env python3` would depend on the `PATH` it is given, so `path/0` is a
  small executable that runs the script with the Python of the test node, by its full
  path. The executable is never changed once it is written: its name holds a hash of its
  text (which has the path of the script and the one of Python), it is in the build
  directory of the project (`_build/test/fake-chrome`, which only the user owns), and it
  is written under a name of its own and then renamed. Two runs of the tests at the same
  time, from two checkouts or with another `PATH`, each get the file that is theirs, and
  the same text is written to the same file, so nobody ever runs a file that is being
  written.

      {:ok, chrome} = FakeChrome.start_link(user_data_dir: dir)
  """

  @script Path.expand("fake_chrome.py", __DIR__)

  @doc "The program to give as `chrome_path`."
  def path do
    case :persistent_term.get({__MODULE__, :path}, nil) do
      nil -> make_launcher()
      path -> path
    end
  end

  @doc """
  Starts `IkeEmails.Chrome` with the fake, and a user data directory that is deleted when
  the test ends. The options are those of `IkeEmails.Chrome.start_link/1`, which win.
  """
  def start_link(opts \\ []) do
    dir = Keyword.get_lazy(opts, :user_data_dir, &user_data_dir/0)
    opts = Keyword.merge([chrome_path: path(), user_data_dir: dir], opts)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    IkeEmails.Chrome.start_link(opts)
  end

  @doc "A path for a user data directory that does not exist yet."
  def user_data_dir do
    Path.join(System.tmp_dir!(), "ike-fake-chrome-#{System.unique_integer([:positive])}")
  end

  @doc "Whether the process with this id (the `FAKE:PID` of the fake) is running."
  def alive?(os_pid) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  # Not a shim of pyenv or mise, which needs the environment that Chrome does not get
  defp real_python do
    shim =
      System.find_executable("python3") ||
        raise "the tests of Chrome need python3 on the PATH, and there is none"

    case System.cmd(shim, ["-I", "-c", "import sys; print(sys.executable)"],
           stderr_to_stdout: true
         ) do
      {path, 0} when path != "" ->
        String.trim(path)

      _failed ->
        raise "the tests of Chrome need python3, and #{shim} does not run"
    end
  end

  defp make_launcher do
    launcher = "#!/bin/sh\nexec '#{real_python()}' -I '#{@script}' \"$@\"\n"
    path = install_launcher!(Path.join(Mix.Project.build_path(), "fake-chrome"), launcher)

    :persistent_term.put({__MODULE__, :path}, path)
    path
  end

  @doc false
  # The text decides the name, so that a file is written once and is the same for ever.
  # It is written whole under a name of its own, and renamed: the rename is atomic, and
  # if another run writes the same file meanwhile, it is the same text
  def install_launcher!(dir, launcher) do
    hash = :sha256 |> :crypto.hash(launcher) |> Base.url_encode64(padding: false)
    path = Path.join(dir, "chrome-" <> binary_part(hash, 0, 16))

    unless File.exists?(path) do
      File.mkdir_p!(dir)
      temporary = Path.join(dir, ".writing-#{System.pid()}-#{System.unique_integer([:positive])}")

      try do
        File.write!(temporary, launcher)
        File.chmod!(temporary, 0o755)
        File.rename!(temporary, path)
      after
        File.rm(temporary)
      end
    end

    path
  end
end
