defmodule IkeEmailsWeb.TransactionController do
  use IkeEmailsWeb, :controller

  alias IkeEmails.Banking

  def create(conn, params) do
    case Banking.create_transaction(params) do
      {:ok, :created, transaction} ->
        conn
        |> put_status(:created)
        |> render(:show, transaction: transaction)

      {:ok, :existing, transaction} ->
        render(conn, :show, transaction: transaction)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end
end
