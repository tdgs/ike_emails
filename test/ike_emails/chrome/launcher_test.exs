defmodule IkeEmails.Chrome.LauncherTest do
  # It sets the environment of the node
  use ExUnit.Case, async: false

  alias IkeEmails.Chrome.Launcher
  alias IkeEmails.FakeChrome

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    names = [
      "CHROME_PATH",
      "PATH",
      "DISPLAY",
      "WAYLAND_DISPLAY",
      "XDG_RUNTIME_DIR",
      "SECRET_FOR_TEST_ONLY"
    ]

    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    System.delete_env("CHROME_PATH")
    {:ok, dir: Path.join(tmp_dir, "profile"), chrome: FakeChrome.path()}
  end

  defp command(opts), do: Launcher.command(opts)

  describe "command/1" do
    test "starts the program through env, so that the node's environment is not inherited", %{
      dir: dir,
      chrome: chrome
    } do
      assert {:ok, %{executable: "/usr/bin/env", args: ["-i", "HOME=" <> home | rest]}} =
               command(chrome_path: chrome, user_data_dir: dir)

      assert home == dir
      assert chrome in rest
    end

    test "gives Chrome the HOME, the PATH, and nothing else", %{dir: dir, chrome: chrome} do
      System.put_env("PATH", "/usr/bin:/bin")
      System.put_env("DISPLAY", ":0")
      System.put_env("SECRET_FOR_TEST_ONLY", "SENTINEL")

      {:ok, %{args: args}} = command(chrome_path: chrome, user_data_dir: dir)
      variables = args |> Enum.take_while(&(&1 != chrome)) |> Enum.drop(1)

      assert variables == ["HOME=" <> dir, "PATH=/usr/bin:/bin"]
    end

    test "gives Chrome the display when it has a window", %{dir: dir, chrome: chrome} do
      System.put_env("PATH", "/usr/bin")
      System.put_env("DISPLAY", ":0")
      System.put_env("WAYLAND_DISPLAY", "wayland-0")
      System.put_env("XDG_RUNTIME_DIR", "/run/user/1000")

      {:ok, %{args: args}} = command(chrome_path: chrome, user_data_dir: dir, headless: false)
      variables = args |> Enum.take_while(&(&1 != chrome)) |> Enum.drop(1)

      assert variables == [
               "HOME=" <> dir,
               "PATH=/usr/bin",
               "DISPLAY=:0",
               "WAYLAND_DISPLAY=wayland-0",
               "XDG_RUNTIME_DIR=/run/user/1000"
             ]
    end

    test "takes the home from the option", %{dir: dir, chrome: chrome} do
      {:ok, %{args: args}} = command(chrome_path: chrome, user_data_dir: dir, home: "/tmp/h")

      assert "HOME=/tmp/h" in args
    end

    test "controls Chrome through the pipe, with the profile and the usual flags", %{
      dir: dir,
      chrome: chrome
    } do
      {:ok, %{args: args}} = command(chrome_path: chrome, user_data_dir: dir)
      flags = args |> Enum.drop_while(&(&1 != chrome)) |> tl()

      assert "--remote-debugging-pipe" in flags
      assert ("--user-data-dir=" <> dir) in flags
      assert "--headless" in flags
      assert "--lang=en-US" in flags
      assert "--password-store=basic" in flags
      assert "--no-first-run" in flags
      assert List.last(flags) == "about:blank"
    end

    test "leaves out the sandbox only when asked to", %{dir: dir, chrome: chrome} do
      {:ok, %{args: default}} = command(chrome_path: chrome, user_data_dir: dir)
      {:ok, %{args: off}} = command(chrome_path: chrome, user_data_dir: dir, no_sandbox: true)
      {:ok, %{args: on}} = command(chrome_path: chrome, user_data_dir: dir, no_sandbox: false)

      refute "--no-sandbox" in default
      refute "--no-sandbox" in on
      assert "--no-sandbox" in off
    end

    test "shows a window when it is not headless", %{dir: dir, chrome: chrome} do
      {:ok, %{args: args}} = command(chrome_path: chrome, user_data_dir: dir, headless: false)

      refute "--headless" in args
    end

    test "takes the language and the extra arguments, which come last", %{
      dir: dir,
      chrome: chrome
    } do
      {:ok, %{args: args}} =
        command(
          chrome_path: chrome,
          user_data_dir: dir,
          lang: "el",
          extra_args: ["--log-level=0", "--window-size=800,600"]
        )

      assert "--lang=el" in args
      refute "--lang=en-US" in args

      flags = Enum.drop_while(args, &(&1 != chrome))

      assert Enum.find_index(flags, &(&1 == "--log-level=3")) <
               Enum.find_index(flags, &(&1 == "--log-level=0"))

      assert "--window-size=800,600" in flags
    end

    test "requires a user data directory", %{chrome: chrome} do
      assert command(chrome_path: chrome) == {:error, :user_data_dir_required}
      assert command(chrome_path: chrome, user_data_dir: "") == {:error, :user_data_dir_required}
      assert command(chrome_path: chrome, user_data_dir: nil) == {:error, :user_data_dir_required}
    end
  end

  describe "command/1 finding Chrome" do
    test "takes the path from the option over the environment", %{dir: dir, chrome: chrome} do
      System.put_env("CHROME_PATH", "/nonexistent/chrome")

      assert {:ok, %{args: args}} = command(chrome_path: chrome, user_data_dir: dir)
      assert chrome in args
    end

    test "takes the path from CHROME_PATH", %{dir: dir, chrome: chrome} do
      System.put_env("CHROME_PATH", chrome)

      assert {:ok, %{args: args}} = command(user_data_dir: dir)
      assert chrome in args
    end

    test "takes the first of the usual names on the PATH", %{
      dir: dir,
      chrome: chrome,
      tmp_dir: bin
    } do
      File.ln_s!(chrome, Path.join(bin, "google-chrome"))
      File.ln_s!(chrome, Path.join(bin, "chromium-browser"))
      System.put_env("PATH", bin)

      assert {:ok, %{args: args}} = command(user_data_dir: dir)
      assert Path.join(bin, "chromium-browser") in args
    end

    test "returns an error when the path is not a program", %{dir: dir, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "text"), "not a program")

      assert command(chrome_path: "/nonexistent/chrome", user_data_dir: dir) ==
               {:error, :chrome_not_found}

      assert command(chrome_path: Path.join(tmp_dir, "text"), user_data_dir: dir) ==
               {:error, :chrome_not_found}

      assert command(chrome_path: tmp_dir, user_data_dir: dir) == {:error, :chrome_not_found}
    end

    test "returns an error when there is none to be found", %{dir: dir, tmp_dir: empty} do
      System.put_env("PATH", empty)

      # On a Mac with Chrome installed the application is found
      if File.exists?("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") do
        assert {:ok, _command} = command(user_data_dir: dir)
      else
        assert command(user_data_dir: dir) == {:error, :chrome_not_found}
      end
    end
  end
end
