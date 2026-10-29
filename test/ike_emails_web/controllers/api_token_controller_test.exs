defmodule IkeEmailsWeb.ApiTokenControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmailsWeb.ApiToken

  setup do
    user = user_fixture()
    %{user: user, scope: user_scope_fixture(user)}
  end

  defp post_token(conn, params), do: post(conn, ~p"/api/auth/token", params)

  test "gives a token for the email and password of a user", %{conn: conn, user: user} do
    conn = post_token(conn, %{"email" => user.email, "password" => valid_user_password()})

    assert %{"data" => %{"token" => token, "token_type" => "Bearer", "expires_in" => expires_in}} =
             json_response(conn, 200)

    assert expires_in == ApiToken.max_age()
    assert ApiToken.verify(token) == {:ok, user.id}
  end

  test "gives a token that pushes transactions for that user", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    %{"data" => %{"token" => token}} =
      conn
      |> post_token(%{"email" => user.email, "password" => valid_user_password()})
      |> json_response(200)

    transaction = %{
      "date" => "2026-10-19",
      "value_date" => "2026-10-17",
      "description" => "ANTHROPIC* CLAUDE SU",
      "transaction_id" => "202610190993537650",
      "amount" => "-90.00"
    }

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/transactions", transaction)

    assert json_response(conn, 201)
    assert [%{description: "ANTHROPIC* CLAUDE SU"}] = Banking.list_transactions(scope)
  end

  test "takes the email in any case", %{conn: conn, user: user} do
    conn =
      post_token(conn, %{
        "email" => String.upcase(user.email),
        "password" => valid_user_password()
      })

    assert json_response(conn, 200)
  end

  test "refuses a wrong password", %{conn: conn, user: user} do
    conn = post_token(conn, %{"email" => user.email, "password" => "not the password"})

    assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  test "refuses an unknown email the same way", %{conn: conn} do
    conn =
      post_token(conn, %{"email" => "nobody@example.com", "password" => valid_user_password()})

    assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  test "refuses a request without the email or the password", %{conn: conn, user: user} do
    assert conn |> post_token(%{"email" => user.email}) |> json_response(401)

    assert build_conn()
           |> post_token(%{"password" => valid_user_password()})
           |> json_response(401)

    assert build_conn() |> post_token(%{}) |> json_response(401)
  end

  test "refuses an email and a password that are not strings", %{conn: conn} do
    assert conn |> post_token(%{"email" => 1, "password" => ["a"]}) |> json_response(401)
  end
end
