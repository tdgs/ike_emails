defmodule IkeEmails.Bank.Driver.ChromeContextTest do
  @moduledoc """
  The driver with `IkeEmails.Chrome` and the stand-in for Chrome of
  `test/support/fake_chrome.py`, which keeps the browser contexts as Chrome does: what
  the driver leaves open in the browser shows in it. Nothing here runs a real Chrome.
  """

  # The stand-in is a program that is made once, in a place that all share
  use ExUnit.Case, async: false

  alias IkeEmails.Bank.Driver.Chrome, as: Driver
  alias IkeEmails.Chrome
  alias IkeEmails.FakeChrome

  # The fake loads these addresses in the ways its documentation tells
  @loads "http://example.test/login"
  @never_loads "http://never.test/login"
  @fails "http://fail.test/login"

  defp open!(opts) do
    opts = opts ++ [chrome_opts: [chrome_path: FakeChrome.path()], login_url: @loads]
    {:ok, session} = Driver.open(opts)

    on_exit(fn ->
      Driver.close(session)
      if session.remove_profile, do: File.rm_rf(session.profile_dir)
    end)

    session
  end

  defp contexts(session) do
    assert {:ok, %{"browserContextIds" => ids}} =
             Chrome.call(session.chrome, "Target.getBrowserContexts")

    ids
  end

  defp targets(session) do
    assert {:ok, %{"targetInfos" => infos}} = Chrome.call(session.chrome, "Target.getTargets")
    Map.new(infos, &{&1["targetId"], &1["browserContextId"]})
  end

  test "opens the login page in a context of its own when the driver made the profile" do
    session = open!([])

    assert {:ok, page} = Driver.login_page(session)

    assert is_binary(page.browser_context_id)
    assert contexts(session) == [page.browser_context_id]
    assert targets(session) == %{page.target_id => page.browser_context_id}
  end

  test "has a fresh context for every login page, and none of the one before" do
    session = open!([])

    {:ok, first} = Driver.login_page(session)
    {:ok, second} = Driver.login_page(session)
    {:ok, third} = Driver.login_page(session)

    ids = [first, second, third] |> Enum.map(& &1.browser_context_id) |> Enum.uniq()
    assert length(ids) == 3
    assert contexts(session) == [third.browser_context_id]
    assert targets(session) == %{third.target_id => third.browser_context_id}
  end

  test "does not leave a context behind when the login page cannot be loaded" do
    session = open!(login_url: @fails)

    assert Driver.login_page(session) ==
             {:error, {:navigation_failed, "net::ERR_NAME_NOT_RESOLVED"}}

    assert Driver.login_page(session) ==
             {:error, {:navigation_failed, "net::ERR_NAME_NOT_RESOLVED"}}

    # The page of the last try is the one that is kept, and the next try or close/1 closes it
    assert {:ok, page} = Driver.current_page(session)
    assert contexts(session) == [page.browser_context_id]
  end

  test "opens the login page in the default context when the profile is given" do
    dir = Path.join(System.tmp_dir!(), "bank-given-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    session = open!(user_data_dir: dir)

    assert {:ok, page} = Driver.login_page(session)
    assert {:ok, _again} = Driver.login_page(session)

    assert page.browser_context_id == nil
    assert contexts(session) == []
  end

  test "opens it in a context of its own for a profile that is given when told to" do
    dir = Path.join(System.tmp_dir!(), "bank-given-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    session = open!(user_data_dir: dir, isolated: true)

    assert {:ok, page} = Driver.login_page(session)

    assert contexts(session) == [page.browser_context_id]
  end

  test "opens it in the default context for a profile that the driver made when told to" do
    session = open!(isolated: false)

    assert {:ok, page} = Driver.login_page(session)

    assert page.browser_context_id == nil
    assert contexts(session) == []
  end

  test "returns the login page when the request for it is answered, and does not wait for it to load" do
    session = open!(login_url: @never_loads)
    started = System.monotonic_time(:millisecond)

    assert {:ok, page} = Driver.login_page(session)

    # The fake never loads this address, and the driver waits 30 seconds for a load
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert {:ok, ^page} = Driver.current_page(session)
  end
end
