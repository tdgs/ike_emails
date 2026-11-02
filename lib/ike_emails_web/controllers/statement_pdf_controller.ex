defmodule IkeEmailsWeb.StatementPdfController do
  use IkeEmailsWeb, :controller

  alias IkeEmails.Statements

  @doc """
  The PDFs are in S3: send the browser there with a link that expires.
  """
  def show(conn, %{"id" => id}) do
    statement = Statements.get_statement!(conn.assigns.current_scope, id)
    redirect(conn, external: Statements.pdf_url(statement))
  end
end
