defmodule IkeEmailsWeb.StatementController do
  use IkeEmailsWeb, :controller

  alias IkeEmails.Statements

  @doc """
  Files the PDF in the `file` field as the statement of the month in the path.
  """
  def create(conn, %{"month" => month, "file" => %Plug.Upload{} = upload}) do
    case Statements.put_statement(
           conn.assigns.current_scope,
           month,
           File.read!(upload.path),
           upload.filename
         ) do
      {:ok, :created, statement} ->
        conn
        |> put_status(:created)
        |> render(:show, statement: statement)

      {:ok, _replaced_or_existing, statement} ->
        render(conn, :show, statement: statement)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)

      {:error, :not_a_pdf} ->
        error(conn, :unprocessable_entity, %{file: ["is not a PDF"]})

      {:error, :too_large} ->
        error(conn, :request_entity_too_large, %{file: ["is too large"]})

      {:error, {:storage, _reason}} ->
        error(conn, :service_unavailable, %{detail: "Could not store the PDF, try again"})
    end
  end

  def create(conn, _params) do
    error(conn, :unprocessable_entity, %{file: ["can't be blank"]})
  end

  defp error(conn, status, errors) do
    conn
    |> put_status(status)
    |> render(:error, errors: errors)
  end
end
