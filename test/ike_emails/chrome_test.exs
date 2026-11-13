defmodule IkeEmails.ChromeTest do
  # It sets the environment of the node, which the Chrome of a test must not get
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias IkeEmails.Chrome
  alias IkeEmails.Chrome.Page
  alias IkeEmails.Chrome.Secret
  alias IkeEmails.FakeChrome

  @sentinel "SENTINEL-p4ss-Ωmega"

  # Chrome here is a script that answers as the protocol says, see
  # test/support/fake_chrome.py for what it does with an expression

  setup do
    {:ok, chrome} = FakeChrome.start_link()
    {:ok, page} = Chrome.new_page(chrome)

    %{chrome: chrome, page: page}
  end

  defp pending(chrome), do: :sys.get_state(chrome).pending

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end

  defp contexts(chrome) do
    assert {:ok, %{"browserContextIds" => ids}} = Chrome.call(chrome, "Target.getBrowserContexts")
    ids
  end

  # The browser context of each target that is open, by the id of the target
  defp targets(chrome) do
    assert {:ok, %{"targetInfos" => infos}} = Chrome.call(chrome, "Target.getTargets")
    Map.new(infos, &{&1["targetId"], &1["browserContextId"]})
  end

  defp fail_next(chrome, method) do
    assert {:ok, %{}} = Chrome.call(chrome, "Fake.failNext", %{method: method})
  end

  defp os_pid(chrome, page) do
    {:ok, os_pid} = Chrome.evaluate(chrome, page, "FAKE:PID")
    os_pid
  end

  describe "start_link/1" do
    test "returns an error when there is no Chrome" do
      assert Chrome.start_link(chrome_path: "/nonexistent/chrome", user_data_dir: "/tmp/x") ==
               {:error, :chrome_not_found}
    end

    test "returns an error when there is no user data directory" do
      assert Chrome.start_link(chrome_path: FakeChrome.path()) ==
               {:error, :user_data_dir_required}
    end

    test "starts Chrome with the pipe, the profile, and the sandbox on" do
      dir = FakeChrome.user_data_dir()
      {:ok, chrome} = FakeChrome.start_link(user_data_dir: dir)
      {:ok, page} = Chrome.new_page(chrome)

      {:ok, args} = Chrome.evaluate(chrome, page, "FAKE:ARGV")

      assert "--remote-debugging-pipe" in args
      assert ("--user-data-dir=" <> dir) in args
      refute "--no-sandbox" in args
    end

    test "starts Chrome without the sandbox when told to" do
      {:ok, chrome} = FakeChrome.start_link(no_sandbox: true)
      {:ok, page} = Chrome.new_page(chrome)

      assert {:ok, args} = Chrome.evaluate(chrome, page, "FAKE:ARGV")
      assert "--no-sandbox" in args
    end

    test "starts Chrome without the environment of the node" do
      System.put_env("SECRET_FOR_TEST_ONLY", @sentinel)
      on_exit(fn -> System.delete_env("SECRET_FOR_TEST_ONLY") end)

      dir = FakeChrome.user_data_dir()
      {:ok, chrome} = FakeChrome.start_link(user_data_dir: dir)
      {:ok, page} = Chrome.new_page(chrome)

      {:ok, environment} = Chrome.evaluate(chrome, page, "FAKE:ENV")

      refute Map.has_key?(environment, "SECRET_FOR_TEST_ONLY")
      refute inspect(environment) =~ @sentinel
      assert environment["HOME"] == dir
      assert environment["PATH"] == System.get_env("PATH")
    end

    test "registers the process under a name" do
      {:ok, chrome} = FakeChrome.start_link(name: :named_fake_chrome)

      assert Process.whereis(:named_fake_chrome) == chrome

      assert {:ok, %{"product" => "FakeChrome/1"}} =
               Chrome.call(:named_fake_chrome, "Browser.getVersion")
    end
  end

  describe "new_page/2" do
    test "returns a page with the target and the session", %{chrome: chrome} do
      assert {:ok, %Page{target_id: "TARGET-" <> _, session_id: "SESSION-" <> _} = page} =
               Chrome.new_page(chrome)

      assert {:ok, other} = Chrome.new_page(chrome)
      assert other.target_id != page.target_id
      assert other.session_id != page.session_id
    end

    test "opens the page in the default context unless told otherwise", %{
      chrome: chrome,
      page: page
    } do
      assert page.browser_context_id == nil
      assert {:ok, other} = Chrome.new_page(chrome, context: :default)
      assert other.browser_context_id == nil

      assert contexts(chrome) == []
      assert targets(chrome)[page.target_id] == "DEFAULT"
    end

    test "opens an isolated page in a context of its own", %{chrome: chrome, page: page} do
      assert {:ok, %Page{browser_context_id: context} = isolated} =
               Chrome.new_page(chrome, context: :isolated)

      assert is_binary(context)
      assert contexts(chrome) == [context]
      assert targets(chrome)[isolated.target_id] == context
      assert targets(chrome)[page.target_id] == "DEFAULT"

      assert Chrome.evaluate(chrome, isolated, "1") == {:ok, 42}
    end

    test "gives every isolated page a context of its own", %{chrome: chrome} do
      {:ok, first} = Chrome.new_page(chrome, context: :isolated)
      {:ok, second} = Chrome.new_page(chrome, context: :isolated)

      assert first.browser_context_id != second.browser_context_id

      assert Enum.sort(contexts(chrome)) ==
               Enum.sort([first, second] |> Enum.map(& &1.browser_context_id))
    end

    test "raises for a context that is not known", %{chrome: chrome} do
      assert_raise ArgumentError, fn -> Chrome.new_page(chrome, context: :private) end
      assert contexts(chrome) == []
    end

    test "disposes of the context when the page cannot be created", %{chrome: chrome, page: page} do
      fail_next(chrome, "Target.createTarget")

      assert Chrome.new_page(chrome, context: :isolated) == {:error, {:cdp_error, -32_000}}

      assert contexts(chrome) == []
      assert Map.keys(targets(chrome)) == [page.target_id]
    end

    test "disposes of the context, and closes the page, when it cannot be attached", %{
      chrome: chrome,
      page: page
    } do
      fail_next(chrome, "Target.attachToTarget")

      assert Chrome.new_page(chrome, context: :isolated) == {:error, {:cdp_error, -32_000}}

      assert contexts(chrome) == []
      assert Map.keys(targets(chrome)) == [page.target_id]
    end

    test "disposes of the context, and closes the page, when it cannot be set up", %{
      chrome: chrome,
      page: page
    } do
      fail_next(chrome, "Page.enable")

      assert Chrome.new_page(chrome, context: :isolated) == {:error, {:cdp_error, -32_000}}

      assert contexts(chrome) == []
      assert Map.keys(targets(chrome)) == [page.target_id]
    end

    test "has no page when the context cannot be made", %{chrome: chrome, page: page} do
      fail_next(chrome, "Target.createBrowserContext")

      assert Chrome.new_page(chrome, context: :isolated) == {:error, {:cdp_error, -32_000}}

      assert Map.keys(targets(chrome)) == [page.target_id]
    end
  end

  describe "close_page/3" do
    test "disposes of the context of an isolated page, and of that one only", %{chrome: chrome} do
      {:ok, first} = Chrome.new_page(chrome, context: :isolated)
      {:ok, second} = Chrome.new_page(chrome, context: :isolated)

      assert Chrome.close_page(chrome, first) == :ok

      assert contexts(chrome) == [second.browser_context_id]
      refute Map.has_key?(targets(chrome), first.target_id)
      assert Chrome.evaluate(chrome, first, "1") == {:error, :page_closed}
      assert Chrome.evaluate(chrome, second, "1") == {:ok, 42}

      assert Chrome.close_page(chrome, second) == :ok
      assert contexts(chrome) == []
    end

    test "leaves the default context alone", %{chrome: chrome, page: page} do
      {:ok, isolated} = Chrome.new_page(chrome, context: :isolated)

      assert Chrome.close_page(chrome, isolated) == :ok

      assert Chrome.evaluate(chrome, page, "1") == {:ok, 42}
      assert Map.keys(targets(chrome)) == [page.target_id]
    end

    test "disposes of the context also when the page was gone already", %{chrome: chrome} do
      {:ok, isolated} = Chrome.new_page(chrome, context: :isolated)

      assert {:ok, _result} =
               Chrome.call(chrome, "Target.closeTarget", %{targetId: isolated.target_id})

      assert contexts(chrome) == [isolated.browser_context_id]

      assert {:error, {:cdp_error, _code}} = Chrome.close_page(chrome, isolated)

      assert contexts(chrome) == []
    end

    test "is an error the second time, and keeps nothing", %{chrome: chrome} do
      {:ok, isolated} = Chrome.new_page(chrome, context: :isolated)
      assert Chrome.close_page(chrome, isolated) == :ok

      assert {:error, {:cdp_error, _code}} = Chrome.close_page(chrome, isolated)

      assert contexts(chrome) == []
    end

    test "stops the calls that wait on the page of the context", %{chrome: chrome} do
      {:ok, isolated} = Chrome.new_page(chrome, context: :isolated)
      task = Task.async(fn -> Chrome.evaluate(chrome, isolated, "FAKE:NEVER", timeout: 5_000) end)
      assert eventually(fn -> map_size(pending(chrome)) == 1 end)

      assert Chrome.close_page(chrome, isolated) == :ok

      assert Task.await(task) == {:error, :page_closed}
    end
  end

  describe "call/4" do
    test "returns the result of a command of the browser", %{chrome: chrome} do
      assert {:ok, %{"product" => "FakeChrome/1"}} = Chrome.call(chrome, "Browser.getVersion")
    end

    test "returns the code of an error and nothing else", %{chrome: chrome} do
      assert Chrome.call(chrome, "Nothing.here") == {:error, {:cdp_error, -32_601}}
    end

    test "returns an error for params that are not JSON, and goes on", %{chrome: chrome} do
      assert Chrome.call(chrome, "Browser.getVersion", %{a: {:tuple, @sentinel}}) ==
               {:error, :invalid_arguments}

      assert {:ok, _version} = Chrome.call(chrome, "Browser.getVersion")
    end

    test "takes the session of a page", %{chrome: chrome, page: page} do
      assert {:ok, %{}} = Chrome.call(chrome, "Runtime.enable", %{}, session: page)
      assert {:ok, %{}} = Chrome.call(chrome, "Runtime.enable", %{}, session: page.session_id)
    end
  end

  describe "evaluate/4" do
    test "returns the value", %{chrome: chrome, page: page} do
      assert Chrome.evaluate(chrome, page, "1 + 41") == {:ok, 42}
    end

    test "returns nil for undefined", %{chrome: chrome, page: page} do
      assert Chrome.evaluate(chrome, page, "FAKE:UNDEFINED") == {:ok, nil}
    end

    test "takes iodata", %{chrome: chrome, page: page} do
      assert Chrome.evaluate(chrome, page, ["FAKE:", ["ECHO"]]) == {:ok, "FAKE:ECHO"}
    end

    test "does not wait for a promise or act as the user unless told to", %{
      chrome: chrome,
      page: page
    } do
      assert {:ok, flags} = Chrome.evaluate(chrome, page, "FAKE:PARAMS")

      assert flags == %{
               "awaitPromise" => false,
               "userGesture" => false,
               "returnByValue" => true,
               "sessionId" => page.session_id
             }
    end

    test "sends the options to Chrome", %{chrome: chrome, page: page} do
      opts = [await_promise: true, user_gesture: true, return_by_value: false]

      assert {:ok, flags} = Chrome.evaluate(chrome, page, "FAKE:PARAMS", opts)

      assert %{"awaitPromise" => true, "userGesture" => true, "returnByValue" => false} = flags
    end

    test "returns the id of an object that is not returned by value", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.evaluate(chrome, page, "FAKE:OBJECT", return_by_value: false) ==
               {:ok, %{object_id: "OBJECT-1"}}
    end

    test "returns the place of an exception, not its text", %{chrome: chrome, page: page} do
      result = Chrome.evaluate(chrome, page, "FAKE:THROW " <> @sentinel)

      assert result == {:error, {:exception, %{line: 3, column: 7}}}
      refute inspect(result) =~ @sentinel
      refute inspect(result) =~ "FAKE:THROW"
    end

    test "returns the place of an exception of a raw command as well", %{
      chrome: chrome,
      page: page
    } do
      params = %{expression: "FAKE:THROW " <> @sentinel}

      assert {:ok, result} = Chrome.call(chrome, "Runtime.evaluate", params, session: page)

      assert result == %{"exceptionDetails" => %{"lineNumber" => 3, "columnNumber" => 7}}
    end

    test "puts a message from Chrome together when it comes in pieces", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.evaluate(chrome, page, "FAKE:SPLIT") == {:ok, 42}
    end

    test "returns an error for an expression that is not text, and goes on", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.evaluate(chrome, page, {:not, :text}) == {:error, :invalid_arguments}
      assert Chrome.evaluate(chrome, page, "1") == {:ok, 42}
    end

    test "returns an error when it is not answered in time, and forgets the call", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.evaluate(chrome, page, "FAKE:NEVER", timeout: 100) == {:error, :timeout}

      assert pending(chrome) == %{}
      assert {:ok, 42} = Chrome.evaluate(chrome, page, "1")
    end

    test "ignores an answer that comes after the time", %{chrome: chrome, page: page} do
      assert Chrome.evaluate(chrome, page, "FAKE:SLOW", timeout: 100) == {:error, :timeout}
      assert pending(chrome) == %{}

      # The late answer arrives while another call waits, and is not taken for its answer
      assert Chrome.evaluate(chrome, page, "FAKE:SLOW", timeout: 1_000) == {:ok, 42}
      Process.sleep(500)

      refute_received _message
      assert pending(chrome) == %{}
      assert Process.alive?(chrome)
    end

    test "returns that the page is closed for a page that is", %{chrome: chrome, page: page} do
      assert Chrome.close_page(chrome, page) == :ok

      assert Chrome.evaluate(chrome, page, "1") == {:error, :page_closed}
      assert {:ok, 42} = Chrome.evaluate(chrome, elem(Chrome.new_page(chrome), 1), "1")
    end

    test "returns that the page is closed to a call that waits for it", %{
      chrome: chrome,
      page: page
    } do
      other = elem(Chrome.new_page(chrome), 1)
      waiting = Task.async(fn -> Chrome.evaluate(chrome, page, "FAKE:NEVER", timeout: 5_000) end)
      kept = Task.async(fn -> Chrome.evaluate(chrome, other, "FAKE:NEVER", timeout: 600) end)
      assert eventually(fn -> map_size(pending(chrome)) == 2 end)

      assert Chrome.close_page(chrome, page) == :ok

      assert Task.await(waiting) == {:error, :page_closed}
      assert Task.await(kept) == {:error, :timeout}
    end
  end

  describe "navigate/4" do
    test "waits for the load of the document that it started", %{chrome: chrome, page: page} do
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{loader_id: loader_id}} =
               Chrome.navigate(chrome, page, "http://example.test/")

      # The fake sends a load of an older document first, and its own 100 ms later
      assert loader_id =~ ~r/\ALOADER-\d+\z/
      assert System.monotonic_time(:millisecond) - started >= 90
    end

    test "returns at once when the load came before the answer", %{chrome: chrome, page: page} do
      assert {:ok, %{loader_id: "LOADER-" <> _}} =
               Chrome.navigate(chrome, page, "http://early.test/")

      assert pending(chrome) == %{}
    end

    test "does not wait for a navigation that stays in the document", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.navigate(chrome, page, "http://same-document.test/#x") ==
               {:ok, %{loader_id: nil}}
    end

    test "returns the code of the error when Chrome cannot load the page", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.navigate(chrome, page, "http://fail.test/") ==
               {:error, {:navigation_failed, "net::ERR_NAME_NOT_RESOLVED"}}
    end

    test "returns an error when the page does not load in time, and forgets the call", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.navigate(chrome, page, "http://never.test/", timeout: 300) ==
               {:error, :timeout}

      assert pending(chrome) == %{}
    end

    test "waits for the load with wait: :load, which is the default", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.navigate(chrome, page, "http://never.test/", wait: :load, timeout: 300) ==
               {:error, :timeout}
    end

    test "returns when Chrome has answered with wait: :commit, whether the page loads or not", %{
      chrome: chrome,
      page: page
    } do
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{loader_id: "LOADER-" <> _}} =
               Chrome.navigate(chrome, page, "http://never.test/", wait: :commit)

      # The page never loads, and the call did not wait the 30 seconds for it
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert pending(chrome) == %{}

      assert {:ok, %{loader_id: "LOADER-" <> _}} =
               Chrome.navigate(chrome, page, "http://example.test/", wait: :commit)

      # The load that comes later is not taken for the answer of another call
      Process.sleep(200)
      assert pending(chrome) == %{}
      assert {:ok, 42} = Chrome.evaluate(chrome, page, "1")
    end

    test "tells that the page is on the same document with wait: :commit", %{
      chrome: chrome,
      page: page
    } do
      assert Chrome.navigate(chrome, page, "http://same-document.test/#x", wait: :commit) ==
               {:ok, %{loader_id: nil}}
    end

    test "returns the code of the error with wait: :commit as well", %{chrome: chrome, page: page} do
      assert Chrome.navigate(chrome, page, "http://fail.test/", wait: :commit) ==
               {:error, {:navigation_failed, "net::ERR_NAME_NOT_RESOLVED"}}
    end

    test "returns that the page is closed to a navigation that waits for the commit", %{
      chrome: chrome
    } do
      {:ok, page} = Chrome.new_page(chrome)
      assert Chrome.close_page(chrome, page) == :ok

      assert Chrome.navigate(chrome, page, "http://example.test/", wait: :commit) ==
               {:error, :page_closed}
    end

    test "raises for a wait that is not known", %{chrome: chrome, page: page} do
      assert_raise ArgumentError, fn ->
        Chrome.navigate(chrome, page, "http://example.test/", wait: :idle)
      end
    end

    test "is not ended by the load of another page", %{chrome: chrome, page: page} do
      other = elem(Chrome.new_page(chrome), 1)

      task =
        Task.async(fn -> Chrome.navigate(chrome, page, "http://never.test/", timeout: 600) end)

      assert eventually(fn ->
               match?([{_, {_, _, {:load, _}, _}}], Map.to_list(pending(chrome)))
             end)

      assert {:ok, _loaded} = Chrome.navigate(chrome, other, "http://example.test/")

      assert Task.await(task) == {:error, :timeout}
    end
  end

  describe "subscribe/2" do
    test "sends the events to the caller", %{chrome: chrome, page: page} do
      assert Chrome.subscribe(chrome) == :ok

      assert {:ok, 42} = Chrome.evaluate(chrome, page, "FAKE:CONSOLE")

      session = page.session_id

      assert_receive {:chrome_event, "Runtime.consoleAPICalled",
                      %{"args" => [%{"value" => text}]}, ^session}

      assert text == "[crawler] hello"
    end

    test "sends the events of the loading of a page", %{chrome: chrome, page: page} do
      Chrome.subscribe(chrome)

      assert {:ok, _loaded} = Chrome.navigate(chrome, page, "http://example.test/")

      assert_receive {:chrome_event, "Page.lifecycleEvent", %{"name" => "load"}, _session}
    end

    test "sends the events to a process that is given", %{chrome: chrome, page: page} do
      parent = self()

      subscriber =
        spawn_link(fn ->
          receive do
            {:chrome_event, method, _params, _session} -> send(parent, {:got, method})
          end
        end)

      assert Chrome.subscribe(chrome, subscriber) == :ok
      Chrome.evaluate(chrome, page, "FAKE:CONSOLE")

      assert_receive {:got, "Runtime.consoleAPICalled"}
      refute_received {:chrome_event, _method, _params, _session}
    end

    test "drops a process that ends", %{chrome: chrome, page: page} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      Chrome.subscribe(chrome, subscriber)
      Chrome.subscribe(chrome, subscriber)
      assert map_size(:sys.get_state(chrome).subscribers) == 1

      Process.exit(subscriber, :kill)

      assert eventually(fn -> :sys.get_state(chrome).subscribers == %{} end)
      assert {:ok, 42} = Chrome.evaluate(chrome, page, "FAKE:CONSOLE")
    end
  end

  describe "call_script/6" do
    test "types the string of a Secret into the script", %{chrome: chrome, page: page} do
      args = %{selector: "#pw", value: Secret.new(@sentinel)}

      assert {:ok, expression} = Chrome.call_script(chrome, page, "FAKE:ECHO", "fill", args)

      arguments =
        expression
        |> String.replace_prefix("(FAKE:ECHO\n).fill(", "")
        |> String.replace_suffix(")", "")

      assert Jason.decode!(arguments) == %{"selector" => "#pw", "value" => @sentinel}
    end

    test "types a Secret wherever it is", %{chrome: chrome, page: page} do
      args = %{fields: [%{value: Secret.new("a\"b")}]}

      assert {:ok, expression} = Chrome.call_script(chrome, page, "FAKE:ECHO", "fill", args)

      assert expression =~ ~s|{"fields":[{"value":"a\\"b"}]}|
    end

    test "takes the options of evaluate", %{chrome: chrome, page: page} do
      assert {:ok, flags} =
               Chrome.call_script(chrome, page, "FAKE:PARAMS", "f", %{}, await_promise: true)

      assert flags["awaitPromise"] == true
    end

    test "returns the place of an exception, not its text", %{chrome: chrome, page: page} do
      args = %{value: Secret.new(@sentinel)}
      result = Chrome.call_script(chrome, page, "FAKE:THROW", "fill", args)

      assert result == {:error, {:exception, %{line: 3, column: 7}}}
      refute inspect(result) =~ @sentinel
    end

    test "returns an error for a function that is not a name", %{chrome: chrome, page: page} do
      assert Chrome.call_script(chrome, page, "({})", "f(); g", %{}) ==
               {:error, :invalid_function}
    end

    test "returns an error that does not hold arguments that are not JSON", %{
      chrome: chrome,
      page: page
    } do
      result = Chrome.call_script(chrome, page, "({})", "f", %{value: {:tuple, @sentinel}})

      assert result == {:error, :invalid_arguments}
      assert Process.alive?(chrome)
    end
  end

  describe "screenshot/3" do
    test "returns the PNG", %{chrome: chrome, page: page} do
      assert {:ok, <<0x89, "PNG", "\r\n", 0x1A, "\n", _rest::binary>>} =
               Chrome.screenshot(chrome, page)
    end
  end

  describe "a password in the process" do
    test "is not in the state, the status or the process info while it waits for an answer", %{
      chrome: chrome,
      page: page
    } do
      args = %{value: Secret.new(@sentinel)}

      task =
        Task.async(fn ->
          Chrome.call_script(chrome, page, "FAKE:NEVER", "fill", args, timeout: 1_000)
        end)

      assert eventually(fn -> map_size(pending(chrome)) == 1 end)

      refute inspect(:sys.get_state(chrome), limit: :infinity) =~ @sentinel
      refute inspect(:sys.get_status(chrome), limit: :infinity) =~ @sentinel
      refute inspect(Process.info(chrome), limit: :infinity) =~ @sentinel
      assert [{_id, {_from, _timer, "Runtime.evaluate", _session}}] = Map.to_list(pending(chrome))

      assert Task.await(task) == {:error, :timeout}
    end

    test "is not in the state, the status or the process info after the answer", %{
      chrome: chrome,
      page: page
    } do
      args = %{value: Secret.new(@sentinel)}

      assert {:ok, expression} = Chrome.call_script(chrome, page, "FAKE:ECHO", "fill", args)
      assert expression =~ @sentinel

      refute inspect(:sys.get_state(chrome), limit: :infinity) =~ @sentinel
      refute inspect(:sys.get_status(chrome), limit: :infinity) =~ @sentinel
      refute inspect(Process.info(chrome), limit: :infinity) =~ @sentinel
    end

    test "is not in the report of a crash", %{chrome: chrome, page: page} do
      Process.flag(:trap_exit, true)

      # A bad timeout makes the process crash after it has built and sent the command.
      # The password is here a bare string, which nothing but the report hides
      message =
        {:call_script, page.session_id, "FAKE:ECHO", "fill", %{value: @sentinel},
         %{await_promise: false, user_gesture: false, return_by_value: true, timeout: :bogus}}

      log =
        capture_log(fn ->
          assert {{:badarg, _stacktrace}, {GenServer, :call, _call}} =
                   catch_exit(GenServer.call(chrome, message))

          assert_receive {:EXIT, ^chrome, {:badarg, _stacktrace}}
        end)

      assert log =~ "terminating"
      assert log =~ "ArgumentError"
      refute log =~ @sentinel
    end

    test "is not in the report of a call that was refused", %{chrome: chrome, page: page} do
      log =
        capture_log(fn ->
          args = %{value: Secret.new(@sentinel), bad: {:tuple, @sentinel}}

          assert Chrome.call_script(chrome, page, "({})", "f", args) ==
                   {:error, :invalid_arguments}
        end)

      refute log =~ @sentinel
    end
  end

  describe "when Chrome ends" do
    test "the calls that wait return that it ended, and so do the next", %{
      chrome: chrome,
      page: page
    } do
      monitor = Process.monitor(chrome)
      first = Task.async(fn -> Chrome.evaluate(chrome, page, "FAKE:NEVER", timeout: 5_000) end)
      second = Task.async(fn -> Chrome.navigate(chrome, page, "http://never.test/") end)
      assert eventually(fn -> map_size(pending(chrome)) == 2 end)

      assert Chrome.evaluate(chrome, page, "FAKE:EXIT") == {:error, :chrome_exited}

      assert Task.await(first) == {:error, :chrome_exited}
      assert Task.await(second) == {:error, :chrome_exited}
      assert_receive {:DOWN, ^monitor, :process, ^chrome, :normal}

      assert Chrome.evaluate(chrome, page, "1") == {:error, :chrome_exited}
      assert Chrome.call(chrome, "Browser.getVersion") == {:error, :chrome_exited}
      assert Chrome.screenshot(chrome, page) == {:error, :chrome_exited}
    end

    test "the process stops without making the caller exit", %{chrome: chrome, page: page} do
      Chrome.evaluate(chrome, page, "FAKE:EXIT")

      assert eventually(fn -> not Process.alive?(chrome) end)
      assert Process.alive?(self())
    end
  end

  describe "stop/1" do
    test "waits until Chrome has ended", %{chrome: chrome, page: page} do
      os_pid = os_pid(chrome, page)
      assert FakeChrome.alive?(os_pid)

      assert Chrome.stop(chrome) == :ok

      refute FakeChrome.alive?(os_pid)
      refute Process.alive?(chrome)
    end

    test "returns the calls that wait", %{chrome: chrome, page: page} do
      task = Task.async(fn -> Chrome.evaluate(chrome, page, "FAKE:NEVER", timeout: 5_000) end)
      assert eventually(fn -> map_size(pending(chrome)) == 1 end)

      assert Chrome.stop(chrome) == :ok

      assert Task.await(task) == {:error, :chrome_exited}
    end

    test "is not an error when it has ended already", %{chrome: chrome} do
      assert Chrome.stop(chrome) == :ok
      assert Chrome.stop(chrome) == :ok
    end
  end

  describe "the end of the pipe" do
    test "ends Chrome when the process of the client is killed", %{chrome: chrome, page: page} do
      Process.flag(:trap_exit, true)
      os_pid = os_pid(chrome, page)

      Process.exit(chrome, :kill)

      assert eventually(fn -> not FakeChrome.alive?(os_pid) end)
    end

    # The process that started it ends with :killed, which the process of the client
    # reports as it ends
    @tag :capture_log
    test "ends Chrome when the process that started it ends" do
      parent = self()
      dir = FakeChrome.user_data_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      owner =
        spawn(fn ->
          {:ok, chrome} = Chrome.start_link(chrome_path: FakeChrome.path(), user_data_dir: dir)
          {:ok, page} = Chrome.new_page(chrome)
          send(parent, {:started, chrome, os_pid(chrome, page)})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, chrome, os_pid}
      assert FakeChrome.alive?(os_pid)

      Process.exit(owner, :kill)

      assert eventually(fn -> not FakeChrome.alive?(os_pid) end)
      assert eventually(fn -> not Process.alive?(chrome) end)
    end
  end
end
