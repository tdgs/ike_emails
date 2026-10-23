defmodule IkeEmailsWeb.InvoicePdfController do
  use IkeEmailsWeb, :controller

  alias IkeEmails.Invoicing

  @doc """
  The PDFs are in S3: send the browser there with a link that expires.
  """
  def show(conn, %{"id" => id}) do
    invoice = Invoicing.get_invoice!(id)
    redirect(conn, external: Invoicing.pdf_url(invoice))
  end
end
