defmodule IkeEmails.Chrome.Launcher do
  @moduledoc """
  The command that starts Chrome for `IkeEmails.Chrome`: which program, and with which
  arguments and which environment.

  The program is the one in the option `:chrome_path`, else the environment variable
  `CHROME_PATH`, else the first of `chromium`, `chromium-browser`, `google-chrome` and
  `google-chrome-stable` on the `PATH`, else the Chrome of macOS in `/Applications`. When
  there is none, `{:error, :chrome_not_found}`.

  Chrome is not started directly, but by `/usr/bin/env -i`. The option `env:` of a port
  only adds variables to those of the node, and the node holds what Chrome has no
  business with: the key of the endpoint, the database URL, the key that seals the
  credentials of the users. With `-i` it starts with nothing, and gets only:

    * `HOME`, which is the option `:home`, else the user data directory, so that
      what Chrome writes outside of the profile is deleted with it
    * `PATH`
    * `DISPLAY`, `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` when there is a window
      (`headless: false`), to be able to open it

  The options:

    * `:user_data_dir` - required. Chrome refuses to be controlled from outside when it
      uses its default profile, and a profile is locked by one Chrome at a time. It is
      created if it is missing
    * `:chrome_path`, `:home`
    * `:headless` - `true` unless `false`
    * `:lang` - the language of the browser, `"en-US"`
    * `:no_sandbox` - leaves out the sandbox of Chrome, which a container without the
      permissions for it needs; `false`. It lets a hole in a page reach the host, so it is
      never the default
    * `:extra_args` - appended to the arguments, so they win when they repeat a flag
  """

  @env "/usr/bin/env"
  @names ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]
  @macos "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  @display_variables ["DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]

  @type command :: %{executable: String.t(), args: [String.t()]}

  @doc """
  The command for the options, as `%{executable: path, args: list}`, or
  `{:error, :chrome_not_found}`, or `{:error, :user_data_dir_required}`.
  """
  @spec command(keyword()) ::
          {:ok, command()} | {:error, :chrome_not_found | :user_data_dir_required}
  def command(opts) do
    with {:ok, user_data_dir} <- user_data_dir(opts),
         {:ok, chrome} <- find_chrome(opts) do
      home = Keyword.get(opts, :home, user_data_dir)
      headless? = Keyword.get(opts, :headless, true)

      args = ["-i" | environment(home, headless?)] ++ [chrome | flags(opts, user_data_dir)]
      {:ok, %{executable: @env, args: args}}
    end
  end

  defp user_data_dir(opts) do
    case Keyword.get(opts, :user_data_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, Path.expand(dir)}
      _missing -> {:error, :user_data_dir_required}
    end
  end

  defp find_chrome(opts) do
    candidates = [
      Keyword.get(opts, :chrome_path),
      System.get_env("CHROME_PATH")
    ]

    configured = Enum.find(candidates, &(is_binary(&1) and &1 != ""))

    path =
      if configured,
        do: Path.expand(configured),
        else: Enum.find_value(@names, &System.find_executable/1) || @macos

    if executable?(path), do: {:ok, path}, else: {:error, :chrome_not_found}
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp environment(home, headless?) do
    names = if headless?, do: ["PATH"], else: ["PATH" | @display_variables]
    passed = for name <- names, value = System.get_env(name), do: name <> "=" <> value

    ["HOME=" <> home | passed]
  end

  defp flags(opts, user_data_dir) do
    headless = if Keyword.get(opts, :headless, true), do: ["--headless"], else: []
    sandbox = if Keyword.get(opts, :no_sandbox, false), do: ["--no-sandbox"], else: []

    ["--remote-debugging-pipe", "--user-data-dir=" <> user_data_dir] ++
      headless ++
      [
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--disable-crash-reporter",
        "--disable-background-networking",
        "--password-store=basic",
        "--use-mock-keychain",
        "--no-first-run",
        "--no-default-browser-check",
        "--log-level=3",
        "--lang=" <> Keyword.get(opts, :lang, "en-US")
      ] ++ sandbox ++ Keyword.get(opts, :extra_args, []) ++ ["about:blank"]
  end
end
