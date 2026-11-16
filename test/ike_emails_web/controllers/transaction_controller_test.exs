defmodule IkeEmailsWeb.TransactionControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  alias IkeEmails.Banking
  alias IkeEmailsWeb.ApiToken

  @transaction %{
    "date" => "2026-10-19",
    "value_date" => "2026-10-17",
    "description" => "ANTHROPIC* CLAUDE SU",
    "branch" => "99",
    "transaction_id" => "202610190993537650",
    "amount" => "-90.00",
    "conversion_details" => nil,
    "sender_details" => "ANTHROPIC* CLAUDE SUB",
    "additional_information" => nil
  }

  setup do
    user = user_fixture()
    %{user: user, scope: user_scope_fixture(user), token: ApiToken.generate(user)}
  end

  defp authorized(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp post_transaction(conn, params) do
    post(conn, ~p"/api/transactions", params)
  end

  describe "authentication" do
    test "rejects a request without a token", %{conn: conn, scope: scope} do
      conn = post_transaction(conn, @transaction)

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
      assert Banking.list_transactions(scope) == []
    end

    test "rejects a request with a token that is not one", %{conn: conn, scope: scope} do
      conn = conn |> authorized("wrong") |> post_transaction(@transaction)

      assert json_response(conn, 401)
      assert Banking.list_transactions(scope) == []
    end

    test "rejects a token that was not signed by the app", %{conn: conn, user: user} do
      forged =
        Phoenix.Token.sign(
          "another secret key base" <> String.duplicate("x", 64),
          "bank api token",
          user.id
        )

      conn = conn |> authorized(forged) |> post_transaction(@transaction)

      assert json_response(conn, 401)
    end

    test "rejects a token that was signed for something else", %{conn: conn, user: user} do
      token = Phoenix.Token.sign(IkeEmailsWeb.Endpoint, "something else", user.id)

      conn = conn |> authorized(token) |> post_transaction(@transaction)

      assert json_response(conn, 401)
    end

    test "rejects an expired token", %{conn: conn, user: user, scope: scope} do
      signed_at = System.system_time(:second) - ApiToken.max_age() - 1
      token = ApiToken.generate(user, signed_at: signed_at)

      conn = conn |> authorized(token) |> post_transaction(@transaction)

      assert json_response(conn, 401)
      assert Banking.list_transactions(scope) == []
    end

    test "accepts a token that is about to expire", %{conn: conn, user: user} do
      signed_at = System.system_time(:second) - ApiToken.max_age() + 60
      token = ApiToken.generate(user, signed_at: signed_at)

      conn = conn |> authorized(token) |> post_transaction(@transaction)

      assert json_response(conn, 201)
    end

    test "rejects the token of a user that is gone", %{conn: conn, user: user} do
      token = ApiToken.generate(user)
      IkeEmails.Repo.delete!(user)

      conn = conn |> authorized(token) |> post_transaction(@transaction)

      assert json_response(conn, 401)
    end

    test "rejects a request with a non bearer authorization", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Basic #{token}")
        |> post_transaction(@transaction)

      assert json_response(conn, 401)
    end

    test "does not take the session of a logged in user for a token", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> post_transaction(@transaction)

      assert json_response(conn, 401)
    end
  end

  describe "create" do
    test "stores a transaction", %{conn: conn, token: token, scope: scope} do
      conn = conn |> authorized(token) |> post_transaction(@transaction)

      assert %{"data" => data} = json_response(conn, 201)

      assert %{
               "date" => "2026-10-19",
               "value_date" => "2026-10-17",
               "description" => "ANTHROPIC* CLAUDE SU",
               "transaction_id" => "202610190993537650",
               "amount" => "-90.00",
               "conversion_details" => nil
             } = data

      assert [%{id: id}] = Banking.list_transactions(scope)
      assert data["id"] == id
    end

    test "stores it for the user of the token only", %{conn: conn, token: token, scope: scope} do
      other = user_scope_fixture()

      conn |> authorized(token) |> post_transaction(@transaction) |> json_response(201)

      assert [%{user_id: user_id}] = Banking.list_transactions(scope)
      assert user_id == scope.user.id
      assert Banking.list_transactions(other) == []
    end

    test "ignores a user id in the params", %{conn: conn, token: token, scope: scope} do
      other = user_scope_fixture()
      params = Map.put(@transaction, "user_id", other.user.id)

      conn |> authorized(token) |> post_transaction(params) |> json_response(201)

      assert [_transaction] = Banking.list_transactions(scope)
      assert Banking.list_transactions(other) == []
    end

    test "returns the stored transaction when it is pushed again", %{
      conn: conn,
      token: token,
      scope: scope
    } do
      conn = conn |> authorized(token) |> post_transaction(@transaction)
      %{"data" => %{"id" => id}} = json_response(conn, 201)

      conn = build_conn() |> authorized(token) |> post_transaction(@transaction)

      assert %{"data" => %{"id" => ^id}} = json_response(conn, 200)
      assert length(Banking.list_transactions(scope)) == 1
    end

    test "stores the same bank line of two users for each", %{conn: conn, token: token} do
      other = user_fixture()
      other_token = ApiToken.generate(other)

      %{"data" => %{"id" => id}} =
        conn |> authorized(token) |> post_transaction(@transaction) |> json_response(201)

      conn = build_conn() |> authorized(other_token) |> post_transaction(@transaction)

      assert %{"data" => %{"id" => other_id}} = json_response(conn, 201)
      assert other_id != id
    end

    test "stores a fee that shares the transaction id of another transaction", %{
      conn: conn,
      token: token,
      scope: scope
    } do
      conn |> authorized(token) |> post_transaction(@transaction) |> json_response(201)

      fee = %{@transaction | "description" => "ΕΞΟΔΑ ΕΝΤΟΛΗΣ", "amount" => "-9.00"}
      conn = build_conn() |> authorized(token) |> post_transaction(fee)

      assert json_response(conn, 201)
      assert length(Banking.list_transactions(scope)) == 2
    end

    test "reports the invalid fields", %{conn: conn, token: token, scope: scope} do
      params =
        %{@transaction | "amount" => "lots", "date" => "yesterday"} |> Map.delete("description")

      conn = conn |> authorized(token) |> post_transaction(params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["amount"] == ["is invalid"]
      assert errors["date"] == ["is invalid"]
      assert errors["description"] == ["can't be blank"]
      assert Banking.list_transactions(scope) == []
    end

    # The columns would refuse them, with a crash and a 500
    test "reports what does not fit the columns", %{conn: conn, token: token, scope: scope} do
      params = %{@transaction | "description" => String.duplicate("x", 256), "amount" => "1e13"}

      conn = conn |> authorized(token) |> post_transaction(params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["description"] == ["should be at most 255 character(s)"]
      assert errors["amount"] == ["must be less than or equal to 9999999999999.99"]
      assert Banking.list_transactions(scope) == []
    end
  end
end
