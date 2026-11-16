defmodule IkeEmailsWeb.StatementControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Repo
  alias IkeEmails.Statements
  alias IkeEmails.Statements.Statement
  alias IkeEmails.Storage.InMemory
  alias IkeEmailsWeb.ApiToken

  setup do
    user = user_fixture()
    %{user: user, scope: user_scope_fixture(user), token: ApiToken.generate(user)}
  end

  defp authorized(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # What the crawler sends: the PDF in the `file` field of a multipart request
  defp upload(content, filename \\ "statement.pdf") do
    path = Path.join(System.tmp_dir!(), "statement-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: filename, content_type: "application/pdf"}
  end

  defp put_statement(conn, month, params) do
    put(conn, ~p"/api/statements/#{month}", params)
  end

  describe "authentication" do
    test "rejects a request without a token", %{conn: conn, scope: scope} do
      conn = put_statement(conn, "2026-10", %{"file" => upload(pdf_fixture())})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
      assert Statements.get_statement(scope, ~D[2026-10-01]) == nil
    end

    test "rejects a request with a token that is not one", %{conn: conn, scope: scope} do
      conn =
        conn
        |> authorized("wrong")
        |> put_statement("2026-10", %{"file" => upload(pdf_fixture())})

      assert json_response(conn, 401)
      assert Statements.get_statement(scope, ~D[2026-10-01]) == nil
    end
  end

  describe "create" do
    # Through the parser of the endpoint, as the crawler sends it: ConnTest hands a
    # %Plug.Upload{} to the controller and skips it
    test "takes a PDF larger than the 8 MB that Plug takes by default",
         %{conn: conn, scope: scope, token: token} do
      pdf = "%PDF-" <> :binary.copy("0", 9_000_000)
      boundary = "statement-boundary"

      body =
        "--#{boundary}\r\n" <>
          ~s|content-disposition: form-data; name="file"; filename="big.pdf"\r\n| <>
          "content-type: application/pdf\r\n\r\n" <>
          pdf <> "\r\n--#{boundary}--\r\n"

      conn =
        conn
        |> authorized(token)
        |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
        |> put(~p"/api/statements/2026-10", body)

      assert json_response(conn, 201)
      assert %Statement{file_size: size} = Statements.get_statement(scope, ~D[2026-10-01])
      assert size == byte_size(pdf)
    end

    test "files the PDF under the month", %{conn: conn, scope: scope, token: token} do
      pdf = pdf_fixture()

      conn =
        conn |> authorized(token) |> put_statement("2026-10", %{"file" => upload(pdf, "oct.pdf")})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["month"] == "2026-10"
      assert data["file_name"] == "oct.pdf"
      assert data["file_size"] == byte_size(pdf)
      assert data["file_sha256"] == :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)

      statement = Statements.get_statement(scope, ~D[2026-10-01])
      assert statement.id == data["id"]
      assert {^pdf, "application/pdf"} = InMemory.get(statement.file_key)
    end

    test "reads the PDF from a multipart body, as curl -F sends it", %{
      conn: conn,
      scope: scope,
      token: token
    } do
      pdf = pdf_fixture()
      boundary = "ike-boundary-#{System.unique_integer([:positive])}"

      body =
        "--#{boundary}\r\n" <>
          ~s(content-disposition: form-data; name="file"; filename="oct.pdf"\r\n) <>
          "content-type: application/pdf\r\n\r\n" <>
          pdf <> "\r\n--#{boundary}--\r\n"

      conn =
        conn
        |> authorized(token)
        |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
        |> put(~p"/api/statements/2026-10", body)

      assert %{"data" => %{"file_name" => "oct.pdf"}} = json_response(conn, 201)

      statement = Statements.get_statement(scope, ~D[2026-10-01])
      assert {^pdf, "application/pdf"} = InMemory.get(statement.file_key)
    end

    test "replaces the statement of the month with a different PDF", %{
      conn: conn,
      scope: scope,
      token: token
    } do
      old = statement_fixture(scope)
      new_pdf = pdf_fixture()

      conn =
        conn
        |> authorized(token)
        |> put_statement("2026-10", %{"file" => upload(new_pdf, "corrected.pdf")})

      assert %{"data" => %{"id" => id, "file_name" => "corrected.pdf"}} = json_response(conn, 200)
      assert id == old.id

      statement = Statements.get_statement(scope, ~D[2026-10-01])
      assert {^new_pdf, _} = InMemory.get(statement.file_key)
      refute InMemory.exists?(old.file_key)
      assert Repo.aggregate(Statement, :count) == 1
    end

    test "sending the same PDF again is fine", %{conn: conn, scope: scope, token: token} do
      pdf = pdf_fixture()
      conn = authorized(conn, token)

      assert %{"data" => %{"id" => id}} =
               conn |> put_statement("2026-10", %{"file" => upload(pdf)}) |> json_response(201)

      assert %{"data" => %{"id" => ^id}} =
               conn |> put_statement("2026-10", %{"file" => upload(pdf)}) |> json_response(200)

      assert Repo.aggregate(Statement, :count) == 1
      assert Statements.get_statement(scope, ~D[2026-10-01]).id == id
    end

    test "keeps a statement per month", %{conn: conn, token: token} do
      conn = authorized(conn, token)

      for month <- ["2026-09", "2026-10"] do
        conn |> put_statement(month, %{"file" => upload(pdf_fixture())}) |> json_response(201)
      end

      assert Repo.aggregate(Statement, :count) == 2
    end

    test "files it for the user of the token whatever the params say", %{
      conn: conn,
      scope: scope,
      token: token
    } do
      other = user_scope_fixture()

      conn =
        conn
        |> authorized(token)
        |> put_statement("2026-10", %{
          "file" => upload(pdf_fixture()),
          "user_id" => other.user.id
        })

      assert json_response(conn, 201)
      assert Statements.get_statement(scope, ~D[2026-10-01])
      assert Statements.get_statement(other, ~D[2026-10-01]) == nil
    end

    test "does not touch the statement of another user", %{conn: conn, token: token} do
      other = user_scope_fixture()
      theirs = statement_fixture(other)

      conn =
        conn |> authorized(token) |> put_statement("2026-10", %{"file" => upload(pdf_fixture())})

      assert json_response(conn, 201)
      assert Statements.get_statement(other, ~D[2026-10-01]).file_key == theirs.file_key
      assert InMemory.exists?(theirs.file_key)
    end

    test "rejects a month that is not YYYY-MM", %{conn: conn, scope: scope, token: token} do
      for month <- ["2026-13", "2026-10-05", "october"] do
        conn =
          conn |> authorized(token) |> put_statement(month, %{"file" => upload(pdf_fixture())})

        assert json_response(conn, 422) == %{"errors" => %{"month" => ["is invalid"]}}
      end

      assert Statements.get_statement(scope, ~D[2026-10-01]) == nil
      assert Repo.aggregate(Statement, :count) == 0
    end

    test "rejects a request without a file", %{conn: conn, token: token} do
      conn = conn |> authorized(token) |> put_statement("2026-10", %{})

      assert json_response(conn, 422) == %{"errors" => %{"file" => ["can't be blank"]}}
    end

    test "rejects a file that is not a PDF", %{conn: conn, token: token} do
      conn =
        conn
        |> authorized(token)
        |> put_statement("2026-10", %{"file" => upload("<html></html>")})

      assert json_response(conn, 422) == %{"errors" => %{"file" => ["is not a PDF"]}}
      assert Repo.aggregate(Statement, :count) == 0
    end
  end
end
