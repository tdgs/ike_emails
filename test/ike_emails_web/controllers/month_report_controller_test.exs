defmodule IkeEmailsWeb.MonthReportControllerTest do
  use IkeEmailsWeb.ConnCase, async: true

  import IkeEmails.Fixtures

  setup :register_and_log_in_user

  test "sends the zip of the month as a download", %{conn: conn, scope: scope} do
    statement_fixture(scope)
    invoice_fixture(scope)

    conn = get(conn, ~p"/reports/2026-10")

    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             ~s(filename="report-2026-10.zip")

    assert {:ok, files} = :zip.unzip(response(conn, 200), [:memory])
    assert length(files) == 2
  end

  test "sends back to the month when it has no statement", %{conn: conn, scope: scope} do
    invoice_fixture(scope)

    conn = get(conn, ~p"/reports/2026-10")

    assert redirected_to(conn) == ~p"/?month=2026-10"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no statement"
  end

  test "is a bad request for a month that is not one", %{conn: conn} do
    assert_error_sent 400, fn -> get(conn, ~p"/reports/october") end
  end

  test "sends whoever is not logged in to the login" do
    conn = get(build_conn(), ~p"/reports/2026-10")

    assert redirected_to(conn) == ~p"/login"
  end
end
