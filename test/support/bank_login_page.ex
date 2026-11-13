defmodule IkeEmails.BankLoginPage do
  @moduledoc """
  A page on `127.0.0.1` that stands in for myAlpha Web in the tests that run a real Chrome
  (`mix test --include chrome`), so that they never need the bank or the network. It is as
  much of the bank as `priv/bank/login.js` and `priv/bank/statements.js` look at:

    * `/myAlphaWeb/business/auth/login` - two login forms of which the first is hidden, a
      field with `username` in its placeholder, a password field, and a button that stays
      disabled until both have a value. The button logs in with the user name `in-use`
      (the bank's message that the account is in use), `stuck` (nothing happens, as when a
      page asks for a code), or any other with the password `right-password`; a wrong
      password shows an error. The page keeps a value in its local storage, `stored_value/0`,
      as the real one keeps what it likes. With the query `?hang` it also asks for an image
      that the server never sends (`/hang`), so the page never finishes loading, as on a
      server that cannot reach the network for what a page fetches besides itself
    * `/myAlphaWeb/business/auth/entry` - a page that replaces itself with the login page
      while it is read, so that it never finishes loading
    * `/myAlphaWeb/business/app/home` - the application: the logout icon (`a.lo`), the
      anti-forgery token of the form that downloads a PDF, and an `angular` whose `$http`
      answers the calls of the script. The details of the transaction `bad` are refused
      with the status 500, those of `refused` with 403
    * `/myAlphaWeb/business/file/GetEStatement` - a PDF
    * `/bye` - where the logout leads

      {server, url} = IkeEmails.BankLoginPage.start()
      url <> "myAlphaWeb/business/auth/login"
  """

  @behaviour Plug

  import Plug.Conn

  @pdf "%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"

  # What the login page keeps in its local storage. The page puts the two parts together,
  # so that the value is not in the text of the page, which Chrome keeps in its cache
  @stored_head "bank-page-local"
  @stored_tail "-storage-value"
  @stored_value @stored_head <> @stored_tail

  @doc "The bytes of the PDF that the page serves."
  def pdf, do: @pdf

  @doc "The value that the login page puts in its local storage."
  def stored_value, do: @stored_value

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{method: "POST", request_path: "/myAlphaWeb/business/file/GetEStatement"} = conn,
        _opts
      ) do
    conn |> put_resp_content_type("application/pdf") |> send_resp(200, @pdf)
  end

  def call(%Plug.Conn{request_path: "/myAlphaWeb/business/auth/login"} = conn, _opts),
    do: html(conn, login(conn.query_string == "hang"))

  def call(%Plug.Conn{request_path: "/myAlphaWeb/business/auth/entry"} = conn, _opts) do
    html(conn, """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8"><title>Entry</title>
        <script>location.replace("/myAlphaWeb/business/auth/login");</script>
      </head>
      <body></body>
    </html>
    """)
  end

  # Never answers, for longer than any test waits
  def call(%Plug.Conn{request_path: "/hang"} = conn, _opts) do
    Process.sleep(:timer.minutes(5))
    send_resp(conn, 504, "")
  end

  def call(%Plug.Conn{request_path: "/myAlphaWeb/business/app/home"} = conn, _opts),
    do: html(conn, home())

  def call(%Plug.Conn{request_path: "/bye"} = conn, _opts),
    do: html(conn, "<!doctype html><title>Bye</title><p>Logged out</p>")

  def call(conn, _opts), do: send_resp(conn, 404, "not found")

  defp html(conn, body) do
    conn |> put_resp_content_type("text/html") |> send_resp(200, body)
  end

  defp login(hang?) do
    image = if hang?, do: ~s(<img src="/hang" alt="">), else: ""

    """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Login</title></head>
      <body>
        <form id="first-form" style="display: none">
          <input type="text" placeholder="Enter your username" id="hidden-user">
          <input type="password" id="hidden-pass">
        </form>
        <form id="login-form">
          <input type="text" id="user" name="user" class="form-control" placeholder="Enter your username">
          <input type="password" id="pass" name="pass" class="form-control" placeholder="Password">
          <button type="button" class="login-button btn" disabled>Log in</button>
          <div class="login-error" style="display: none"></div>
        </form>
        <a href="/somewhere">A link</a>
        #{image}
        <script>
          localStorage.setItem("remembered", "#{@stored_head}" + "#{@stored_tail}");
          const user = document.querySelector("#user");
          const pass = document.querySelector("#pass");
          const button = document.querySelector(".login-button");
          const error = document.querySelector(".login-error");
          const update = () => { button.disabled = !(user.value && pass.value); };
          const fail = (text) => { error.textContent = text; error.style.display = "block"; };
          user.addEventListener("input", update);
          pass.addEventListener("input", update);
          button.addEventListener("click", () => {
            if (user.value === "stuck") return;
            if (user.value === "in-use") return fail("Ο λογαριασμός σας χρησιμοποιείται ήδη, ίσως από άλλον υπολογιστή.");
            if (pass.value === "right-password") location.href = "/myAlphaWeb/business/app/home";
            else fail("The user name or the password is wrong");
          });
        </script>
      </body>
    </html>
    """
  end

  defp home do
    """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Home</title></head>
      <body>
        <a class="lo" href="/bye">Log out</a>
        <input type="hidden" name="__RequestVerificationToken" value="token-1">
        <script>
          const answer = (fields) => {
            if (fields.GetDetails) {
              const id = fields.GetDetails.UN;
              if (id === "bad") return Promise.reject({ status: 500, data: "the bank said something" });
              if (id === "refused") return Promise.reject({ status: 403, data: "blocked" });
              return Promise.resolve({
                ResultCode: 0,
                Statements: [
                  { TransactionUN: id, StatementDetails: [{ SenderDetails: "sender " + id }] },
                ],
              });
            }
            if (fields.GetSummary) {
              return Promise.resolve({
                HasMore: false,
                Statements: [],
                PreviousGrossBalance: 10,
                PreviousGrossBalanceSign: "P",
                NewGrossBalance: 10,
                NewGrossBalanceSign: "P",
              });
            }
            return Promise.resolve({
              ResultCode: 0,
              EStatements: [
                {
                  EStatementIssued: true,
                  EstatementID: "e1",
                  DateFrom: "2026-09-01",
                  DateTo: "2026-09-30",
                  IssuedDate: "2026-10-01",
                },
              ],
            });
          };
          const http = { post: (url, body) => answer(body) };
          window.angular = { element: () => ({ injector: () => ({ get: () => http }) }) };
        </script>
      </body>
    </html>
    """
  end

  @doc "Starts the server on a port that is free. Returns it, and the address of the page."
  def start do
    {:ok, server} =
      Bandit.start_link(
        plug: __MODULE__,
        scheme: :http,
        ip: :loopback,
        port: 0,
        startup_log: false,
        # The script compares the length that the server sent with that of the file
        http_options: [compress: false]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {server, "http://127.0.0.1:#{port}/"}
  end
end
