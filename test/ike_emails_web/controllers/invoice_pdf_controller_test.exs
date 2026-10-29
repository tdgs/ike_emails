defmodule IkeEmailsWeb.InvoicePdfControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  setup :register_and_log_in_user

  test "sends the browser to a temporary link of the stored PDF", %{conn: conn, scope: scope} do
    invoice = invoice_fixture(scope)

    conn = get(conn, ~p"/invoices/#{invoice.id}/pdf")

    assert redirected_to(conn, 302) =~ "http://storage.test/#{invoice.file_key}"
  end

  test "is not found for an unknown invoice", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/invoices/0/pdf") end
  end

  test "is not found for the invoice of another user", %{conn: conn} do
    invoice = invoice_fixture(user_scope_fixture())

    assert_error_sent 404, fn -> get(conn, ~p"/invoices/#{invoice.id}/pdf") end
  end

  test "sends whoever is not logged in to the login" do
    invoice = invoice_fixture(user_scope_fixture())

    conn = get(build_conn(), ~p"/invoices/#{invoice.id}/pdf")

    assert redirected_to(conn) == ~p"/login"
  end
end
