defmodule IkeEmailsWeb.HealthCheckTest do
  use IkeEmailsWeb.ConnCase, async: true

  test "GET /up answers without a login", %{conn: conn} do
    conn = get(conn, "/up")

    assert response(conn, 200) == "ok"
  end
end
