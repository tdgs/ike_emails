defmodule IkeEmails.ChromePage do
  @moduledoc """
  A page on `127.0.0.1` for the tests that run a real Chrome (`mix test --include
  chrome`), so that they never need the network. Every path answers with the same page,
  whose title and heading say which it was.

      {server, url} = IkeEmails.ChromePage.start()
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    html = """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Local test page #{conn.request_path}</title></head>
      <body>
        <h1 id="greeting">Hello</h1>
        <input id="user" value="">
        <script>window.loadedBy = "the test page";</script>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  @doc "Starts the server on a port that is free. Returns it, and the address of the page."
  def start do
    {:ok, server} =
      Bandit.start_link(
        plug: __MODULE__,
        scheme: :http,
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {server, "http://127.0.0.1:#{port}/"}
  end
end
