defmodule IkeEmailsWeb.TransactionControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  alias IkeEmails.Banking

  @token "test-bank-api-token"

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

  defp authorized(conn, token \\ @token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp post_transaction(conn, params) do
    post(conn, ~p"/api/transactions", params)
  end

  describe "authentication" do
    test "rejects a request without a token", %{conn: conn} do
      conn = post_transaction(conn, @transaction)

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
      assert Banking.list_transactions() == []
    end

    test "rejects a request with a wrong token", %{conn: conn} do
      conn = conn |> authorized("wrong") |> post_transaction(@transaction)

      assert json_response(conn, 401)
      assert Banking.list_transactions() == []
    end

    test "rejects a request with a non bearer authorization", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic #{@token}")
        |> post_transaction(@transaction)

      assert json_response(conn, 401)
    end

    test "rejects every request when no token is configured", %{conn: conn} do
      previous = Application.fetch_env!(:ike_emails, :bank_api_token)
      Application.delete_env(:ike_emails, :bank_api_token)
      on_exit(fn -> Application.put_env(:ike_emails, :bank_api_token, previous) end)

      conn = conn |> authorized("") |> post_transaction(@transaction)

      assert json_response(conn, 401)
    end
  end

  describe "create" do
    test "stores a transaction", %{conn: conn} do
      conn = conn |> authorized() |> post_transaction(@transaction)

      assert %{"data" => data} = json_response(conn, 201)

      assert %{
               "date" => "2026-10-19",
               "value_date" => "2026-10-17",
               "description" => "ANTHROPIC* CLAUDE SU",
               "transaction_id" => "202610190993537650",
               "amount" => "-90.00",
               "conversion_details" => nil
             } = data

      assert [%{id: id}] = Banking.list_transactions()
      assert data["id"] == id
    end

    test "returns the stored transaction when it is pushed again", %{conn: conn} do
      conn = conn |> authorized() |> post_transaction(@transaction)
      %{"data" => %{"id" => id}} = json_response(conn, 201)

      conn = build_conn() |> authorized() |> post_transaction(@transaction)

      assert %{"data" => %{"id" => ^id}} = json_response(conn, 200)
      assert length(Banking.list_transactions()) == 1
    end

    test "stores a fee that shares the transaction id of another transaction", %{conn: conn} do
      conn |> authorized() |> post_transaction(@transaction) |> json_response(201)

      fee = %{@transaction | "description" => "ΕΞΟΔΑ ΕΝΤΟΛΗΣ", "amount" => "-9.00"}
      conn = build_conn() |> authorized() |> post_transaction(fee)

      assert json_response(conn, 201)
      assert length(Banking.list_transactions()) == 2
    end

    test "reports the invalid fields", %{conn: conn} do
      params =
        %{@transaction | "amount" => "lots", "date" => "yesterday"} |> Map.delete("description")

      conn = conn |> authorized() |> post_transaction(params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["amount"] == ["is invalid"]
      assert errors["date"] == ["is invalid"]
      assert errors["description"] == ["can't be blank"]
      assert Banking.list_transactions() == []
    end
  end
end
