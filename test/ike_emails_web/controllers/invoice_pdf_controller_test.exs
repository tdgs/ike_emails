defmodule IkeEmailsWeb.InvoicePdfControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  test "sends the browser to a temporary link of the stored PDF", %{conn: conn} do
    invoice = invoice_fixture()

    conn = get(conn, ~p"/invoices/#{invoice.id}/pdf")

    assert redirected_to(conn, 302) =~ "http://storage.test/#{invoice.file_key}"
  end

  test "is not found for an unknown invoice", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/invoices/0/pdf") end
  end
end
