defmodule IkeEmails.ChromeRealTest do
  @moduledoc """
  `IkeEmails.Chrome` with a real Chrome, on a page of this machine
  (`IkeEmails.ChromePage`); nothing here goes to the network.

      mix test --include chrome test/ike_emails/chrome_real_test.exs

  Chrome is the one of `CHROME_PATH`, or the first on the `PATH`, or the Chrome of macOS.
  `CHROME_NO_SANDBOX=1` runs it without its sandbox, which a container as root needs.
  """

  use ExUnit.Case, async: false

  alias IkeEmails.Chrome
  alias IkeEmails.Chrome.Secret
  alias IkeEmails.ChromePage

  @moduletag :chrome
  @moduletag timeout: 120_000

  @png <<0x89, "PNG", "\r\n", 0x1A, "\n">>

  setup_all do
    {server, url} = ChromePage.start()
    {chrome, dir} = start_chrome()

    on_exit(fn -> stop_processes(dir) end)

    %{browser: chrome, url: url, server: server}
  end

  setup %{browser: chrome} do
    {:ok, page} = Chrome.new_page(chrome)
    on_exit(fn -> Chrome.close_page(chrome, page) end)

    %{page: page}
  end

  defp start_chrome(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "ike-real-chrome-#{System.unique_integer([:positive])}")

    opts =
      Keyword.merge(
        [user_data_dir: dir, no_sandbox: System.get_env("CHROME_NO_SANDBOX") == "1"],
        opts
      )

    {:ok, chrome} = Chrome.start_link(opts)
    {chrome, dir}
  end

  # The processes of Chrome that use this profile, which no other does
  defp running?(dir) do
    {_output, status} = System.cmd("pgrep", ["-f", "--", "--user-data-dir=" <> dir])
    status == 0
  end

  defp stop_processes(dir) do
    System.cmd("pkill", ["-f", "--", "--user-data-dir=" <> dir])
    Process.sleep(200)
    File.rm_rf(dir)
  end

  defp gone?(dir, tries \\ 100) do
    cond do
      not running?(dir) -> true
      tries == 0 -> false
      true -> Process.sleep(100) && gone?(dir, tries - 1)
    end
  end

  describe "a page" do
    test "is loaded, and read", %{browser: chrome, page: page, url: url} do
      assert {:ok, %{loader_id: loader_id}} = Chrome.navigate(chrome, page, url <> "first")
      assert is_binary(loader_id)

      assert Chrome.evaluate(chrome, page, "document.title") == {:ok, "Local test page /first"}
      assert Chrome.evaluate(chrome, page, "window.loadedBy") == {:ok, "the test page"}
      assert Chrome.evaluate(chrome, page, "undefined") == {:ok, nil}
    end

    test "is loaded again by a second navigation", %{browser: chrome, page: page, url: url} do
      {:ok, %{loader_id: first}} = Chrome.navigate(chrome, page, url <> "first")
      {:ok, %{loader_id: second}} = Chrome.navigate(chrome, page, url <> "second")

      assert first != second
      assert Chrome.evaluate(chrome, page, "document.title") == {:ok, "Local test page /second"}
    end

    test "is not loaded when the server refuses", %{browser: chrome, page: page} do
      # A port that was free a moment ago, and has nobody listening
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert Chrome.navigate(chrome, page, "http://127.0.0.1:#{port}/") ==
               {:error, {:navigation_failed, "net::ERR_CONNECTION_REFUSED"}}
    end

    test "is photographed", %{browser: chrome, page: page, url: url} do
      {:ok, _loaded} = Chrome.navigate(chrome, page, url)

      assert {:ok, <<@png, _rest::binary>> = png} = Chrome.screenshot(chrome, page)
      assert byte_size(png) > 100
    end

    test "is closed", %{browser: chrome, url: url} do
      {:ok, page} = Chrome.new_page(chrome)
      {:ok, _loaded} = Chrome.navigate(chrome, page, url)

      assert Chrome.close_page(chrome, page) == :ok

      assert Chrome.evaluate(chrome, page, "1") == {:error, :page_closed}
    end

    test "tells the console to a subscriber", %{browser: chrome, page: page} do
      :ok = Chrome.subscribe(chrome)
      session = page.session_id

      assert {:ok, nil} = Chrome.evaluate(chrome, page, ~s|console.log("[crawler] hello")|)

      assert_receive {:chrome_event, "Runtime.consoleAPICalled",
                      %{"args" => [%{"value" => text}]}, ^session},
                     5_000

      assert text == "[crawler] hello"
    end
  end

  describe "navigate/4 with wait: :commit" do
    test "returns the loader of the document that has started", %{
      browser: chrome,
      page: page,
      url: url
    } do
      assert {:ok, %{loader_id: loader_id}} =
               Chrome.navigate(chrome, page, url <> "first", wait: :commit)

      assert is_binary(loader_id)
      assert Chrome.evaluate(chrome, page, "location.pathname") == {:ok, "/first"}
    end

    test "returns the code of the error when Chrome cannot load the page", %{
      browser: chrome,
      page: page
    } do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert Chrome.navigate(chrome, page, "http://127.0.0.1:#{port}/", wait: :commit) ==
               {:error, {:navigation_failed, "net::ERR_CONNECTION_REFUSED"}}
    end
  end

  describe "an isolated page" do
    defp contexts(chrome) do
      {:ok, %{"browserContextIds" => ids}} = Chrome.call(chrome, "Target.getBrowserContexts")
      ids
    end

    test "does not see what the pages of the default context stored", %{
      browser: chrome,
      page: page,
      url: url
    } do
      {:ok, _loaded} = Chrome.navigate(chrome, page, url)

      store = ~s|localStorage.setItem("kept", "by the default")|
      assert Chrome.evaluate(chrome, page, store) == {:ok, nil}

      assert Chrome.evaluate(chrome, page, ~s|document.cookie = "kept=1; path=/"|) ==
               {:ok, "kept=1; path=/"}

      {:ok, isolated} = Chrome.new_page(chrome, context: :isolated)
      on_exit(fn -> Chrome.close_page(chrome, isolated) end)
      {:ok, _loaded} = Chrome.navigate(chrome, isolated, url)

      assert Chrome.evaluate(chrome, isolated, ~s|localStorage.getItem("kept")|) == {:ok, nil}
      assert Chrome.evaluate(chrome, isolated, "document.cookie") == {:ok, ""}

      assert Chrome.evaluate(chrome, page, ~s|localStorage.getItem("kept")|) ==
               {:ok, "by the default"}
    end

    test "does not see what another isolated page stored", %{browser: chrome, url: url} do
      {:ok, first} = Chrome.new_page(chrome, context: :isolated)
      {:ok, second} = Chrome.new_page(chrome, context: :isolated)
      on_exit(fn -> for page <- [first, second], do: Chrome.close_page(chrome, page) end)

      {:ok, _loaded} = Chrome.navigate(chrome, first, url)
      {:ok, _loaded} = Chrome.navigate(chrome, second, url)

      {:ok, nil} =
        Chrome.evaluate(chrome, first, ~s|localStorage.setItem("kept", "by the first")|)

      assert Chrome.evaluate(chrome, first, ~s|localStorage.getItem("kept")|) ==
               {:ok, "by the first"}

      assert Chrome.evaluate(chrome, second, ~s|localStorage.getItem("kept")|) == {:ok, nil}
    end

    test "is gone with its context when the page is closed", %{browser: chrome, url: url} do
      before = contexts(chrome)
      {:ok, isolated} = Chrome.new_page(chrome, context: :isolated)
      assert [context] = contexts(chrome) -- before
      assert context == isolated.browser_context_id

      {:ok, _loaded} = Chrome.navigate(chrome, isolated, url)
      {:ok, nil} = Chrome.evaluate(chrome, isolated, ~s|localStorage.setItem("kept", "yes")|)

      assert Chrome.close_page(chrome, isolated) == :ok

      assert contexts(chrome) == before
      assert Chrome.evaluate(chrome, isolated, "1") == {:error, :page_closed}
    end
  end

  describe "evaluate/4" do
    test "waits for a promise when told to", %{browser: chrome, page: page} do
      expression = ~s|new Promise((resolve) => setTimeout(() => resolve("settled"), 100))|

      assert Chrome.evaluate(chrome, page, expression, await_promise: true) == {:ok, "settled"}
    end

    test "acts as the user when told to", %{browser: chrome, page: page} do
      assert Chrome.evaluate(chrome, page, "navigator.userActivation.isActive") == {:ok, false}

      assert Chrome.evaluate(chrome, page, "navigator.userActivation.isActive",
               user_gesture: true
             ) ==
               {:ok, true}
    end

    test "keeps an object in the page when told to", %{browser: chrome, page: page} do
      assert {:ok, %{object_id: id}} =
               Chrome.evaluate(chrome, page, "({a: 1})", return_by_value: false)

      assert is_binary(id)
    end

    test "returns the place of an exception, and not what it said", %{browser: chrome, page: page} do
      expression = ~s|\n  throw new Error("SENTINEL-p4ss-Ωmega")|

      result = Chrome.evaluate(chrome, page, expression)

      assert {:error, {:exception, %{line: 1, column: column}}} = result
      assert is_integer(column)
      refute inspect(result) =~ "SENTINEL"
    end

    test "returns the place of a rejected promise, and not what it said", %{
      browser: chrome,
      page: page
    } do
      expression = ~s|Promise.reject(new Error("SENTINEL-p4ss-Ωmega"))|

      result = Chrome.evaluate(chrome, page, expression, await_promise: true)

      assert {:error, {:exception, %{line: _line, column: _column}}} = result
      refute inspect(result) =~ "SENTINEL"
    end

    test "returns an error for a script that does not end in time", %{browser: chrome, page: page} do
      assert Chrome.evaluate(chrome, page, "new Promise(() => {})",
               await_promise: true,
               timeout: 500
             ) == {:error, :timeout}

      assert Chrome.evaluate(chrome, page, "1 + 1") == {:ok, 2}
    end
  end

  describe "call_script/6" do
    @script "({ echo: ({ text }) => text, add: ({ a, b }) => a + b, lengthOf: ({ text }) => text.length })"

    test "calls a function with the arguments", %{browser: chrome, page: page} do
      assert Chrome.call_script(chrome, page, @script, "add", %{a: 1, b: 2}) == {:ok, 3}
    end

    test "types a Secret as the string it holds", %{browser: chrome, page: page} do
      line_separator = <<0x2028::utf8>>
      password = ~s|p"4ss' \\ Ωmega 😀 </script>\n| <> line_separator <> "end"
      args = %{text: Secret.new(password)}

      assert Chrome.call_script(chrome, page, @script, "echo", args) == {:ok, password}

      # JavaScript counts in UTF-16 units: the line separator and the emoji are not a unit each
      units =
        password
        |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
        |> byte_size()
        |> div(2)

      assert Chrome.call_script(chrome, page, @script, "lengthOf", args) == {:ok, units}
    end

    test "returns the place of an exception, and not what it said", %{browser: chrome, page: page} do
      script = ~s|({ fail: ({ text }) => { throw new Error("got " + text) } })|
      args = %{text: Secret.new("SENTINEL-p4ss-Ωmega")}

      result = Chrome.call_script(chrome, page, script, "fail", args)

      assert {:error, {:exception, %{line: _line, column: _column}}} = result
      refute inspect(result) =~ "SENTINEL"
    end

    test "returns an error for a script that has no such function", %{browser: chrome, page: page} do
      assert {:error, {:exception, _place}} =
               Chrome.call_script(chrome, page, @script, "nope", %{})
    end
  end

  describe "the end of Chrome" do
    test "is waited for by stop/1" do
      {chrome, dir} = start_chrome()
      on_exit(fn -> stop_processes(dir) end)
      {:ok, _page} = Chrome.new_page(chrome)
      assert running?(dir)

      assert Chrome.stop(chrome) == :ok

      refute running?(dir)
    end

    test "comes when the process of the client is killed, which closes the pipe" do
      {chrome, dir} = start_chrome()
      on_exit(fn -> stop_processes(dir) end)
      Process.flag(:trap_exit, true)
      {:ok, _page} = Chrome.new_page(chrome)
      assert running?(dir)

      Process.exit(chrome, :kill)

      assert gone?(dir), "Chrome is still running after the pipe was closed"
    end

    @tag :capture_log
    test "comes when the process that started it ends" do
      parent = self()
      dir = Path.join(System.tmp_dir!(), "ike-real-chrome-#{System.unique_integer([:positive])}")
      on_exit(fn -> stop_processes(dir) end)

      owner =
        spawn(fn ->
          {:ok, chrome} =
            Chrome.start_link(
              user_data_dir: dir,
              no_sandbox: System.get_env("CHROME_NO_SANDBOX") == "1"
            )

          {:ok, _page} = Chrome.new_page(chrome)
          send(parent, :started)
          Process.sleep(:infinity)
        end)

      assert_receive :started, 30_000
      assert running?(dir)

      Process.exit(owner, :kill)

      assert gone?(dir), "Chrome is still running after its owner was killed"
    end

    test "does not leave a Chrome that was told to stop and was not answered", %{url: url} do
      {chrome, dir} = start_chrome()
      on_exit(fn -> stop_processes(dir) end)
      {:ok, page} = Chrome.new_page(chrome)
      {:ok, _loaded} = Chrome.navigate(chrome, page, url)

      task =
        Task.async(fn ->
          Chrome.evaluate(chrome, page, "new Promise(() => {})",
            await_promise: true,
            timeout: 20_000
          )
        end)

      Process.sleep(200)
      assert Chrome.stop(chrome) == :ok

      assert Task.await(task) == {:error, :chrome_exited}
      refute running?(dir)
    end
  end
end
