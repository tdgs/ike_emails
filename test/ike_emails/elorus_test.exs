defmodule IkeEmails.ElorusTest do
  # Not async: some tests change the configuration of the client
  use ExUnit.Case, async: false

  # The retries are logged
  @moduletag :capture_log

  alias IkeEmails.Elorus
  alias IkeEmails.Elorus.Invoice

  setup do
    original = Application.fetch_env!(:ike_emails, Elorus)
    on_exit(fn -> Application.put_env(:ike_emails, Elorus, original) end)
    :ok
  end

  defp put_config(changes) do
    config = Application.fetch_env!(:ike_emails, Elorus)
    Application.put_env(:ike_emails, Elorus, Keyword.merge(config, changes))
  end

  # The example values of https://developer.elorus.com
  defp invoice_json(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "1050000300010040",
        "status" => "paid",
        "draft" => false,
        "representation" => "Invoice #A-1",
        "number" => "1",
        "sequence_flat" => "A-",
        "date" => "2026-10-25",
        "due_date" => "2026-11-25",
        "client" => "3300000040000100",
        "client_display_name" => "Acme Inc.",
        "client_vat_number" => "123451234",
        "currency_code" => "EUR",
        "net" => "80.00",
        "total" => "100.00",
        "payable" => "100.00",
        "paid" => "100.00",
        "permalink" => "https://app.elorus.com/p/abc/"
      },
      attrs
    )
  end

  defp page_json(results, next \\ nil) do
    %{"count" => length(results), "next" => next, "previous" => nil, "results" => results}
  end

  defp stub_json(body, status \\ 200) do
    test = self()

    Req.Test.stub(Elorus, fn conn ->
      send(test, {:request, conn})

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  describe "configured?/0" do
    test "is true with an API key and an organization" do
      assert Elorus.configured?()
    end

    test "is false without either" do
      put_config(api_token: nil)
      refute Elorus.configured?()

      put_config(api_token: "token", organization_id: "")
      refute Elorus.configured?()
    end

    test "makes no request when it is false" do
      put_config(api_token: nil)
      Req.Test.stub(Elorus, fn _conn -> flunk("no request should be made") end)

      assert Elorus.list_invoices() == {:error, :not_configured}
      assert Elorus.get_invoice("1") == {:error, :not_configured}
      assert Elorus.invoice_pdf("1") == {:error, :not_configured}
    end
  end

  describe "requests" do
    test "carry the API key and the organization" do
      stub_json(page_json([]))

      assert {:ok, _} = Elorus.list_invoices()

      assert_received {:request, conn}
      assert conn.method == "GET"
      assert conn.request_path == "/v1.2/invoices/"
      assert header(conn, "authorization") == "Token test-elorus-token"
      assert header(conn, "x-elorus-organization") == "1000000243015421"
      assert header(conn, "x-elorus-demo") == nil
    end

    test "ask for a demo organization when configured so" do
      put_config(demo: true)
      stub_json(page_json([]))

      assert {:ok, _} = Elorus.list_invoices()

      assert_received {:request, conn}
      assert header(conn, "x-elorus-demo") == "true"
    end
  end

  describe "list_invoices/1" do
    test "parses the invoices" do
      stub_json(page_json([invoice_json(), invoice_json(%{"id" => "2", "total" => "12.50"})]))

      assert {:ok, %{count: 2, more?: false, invoices: [first, second]}} =
               Elorus.list_invoices()

      assert %Invoice{
               id: "1050000300010040",
               status: "paid",
               draft: false,
               representation: "Invoice #A-1",
               number: "1",
               sequence_flat: "A-",
               date: ~D[2026-10-25],
               due_date: ~D[2026-11-25],
               client_id: "3300000040000100",
               client_name: "Acme Inc.",
               client_vat_number: "123451234",
               currency_code: "EUR",
               permalink: "https://app.elorus.com/p/abc/"
             } = first

      assert Decimal.equal?(first.net, "80.00")
      assert Decimal.equal?(first.total, "100.00")
      assert Decimal.equal?(first.payable, "100.00")
      assert Decimal.equal?(first.paid, "100.00")
      assert Decimal.equal?(second.total, "12.50")
      assert first.raw["id"] == "1050000300010040"
    end

    test "passes the filters as query parameters, newest first by default" do
      stub_json(page_json([]))

      assert {:ok, _} =
               Elorus.list_invoices(
                 period_from: ~D[2026-10-01],
                 period_to: ~D[2026-10-31],
                 search: "Acme & Co",
                 page_size: 50
               )

      assert_received {:request, conn}
      params = Plug.Conn.fetch_query_params(conn).query_params

      assert params == %{
               "period_from" => "2026-10-01",
               "period_to" => "2026-10-31",
               "search" => "Acme & Co",
               "page_size" => "50",
               "ordering" => "-date,-created"
             }
    end

    test "sends the flags as 1 and 0" do
      stub_json(page_json([]))

      assert {:ok, _} = Elorus.list_invoices(draft: false, overdue: true, status: "paid")

      assert_received {:request, conn}
      params = Plug.Conn.fetch_query_params(conn).query_params
      assert %{"draft" => "0", "overdue" => "1", "status" => "paid"} = params
    end

    test "lets the caller choose the ordering" do
      stub_json(page_json([]))

      assert {:ok, _} = Elorus.list_invoices(ordering: "total")

      assert_received {:request, conn}
      assert Plug.Conn.fetch_query_params(conn).query_params["ordering"] == "total"
    end

    test "tells that another page follows" do
      stub_json(page_json([invoice_json()], "https://api.elorus.com/v1.2/invoices/?page=2"))

      assert {:ok, %{more?: true}} = Elorus.list_invoices()
    end

    test "leaves out what it cannot parse" do
      stub_json(
        page_json([
          invoice_json(%{
            "date" => "yesterday",
            "due_date" => nil,
            "total" => "a lot",
            "number" => "",
            "client_vat_number" => "",
            "permalink" => ""
          })
        ])
      )

      assert {:ok, %{invoices: [invoice]}} = Elorus.list_invoices()

      assert %Invoice{
               date: nil,
               due_date: nil,
               total: nil,
               number: nil,
               client_vat_number: nil,
               permalink: nil
             } = invoice
    end
  end

  describe "a 200 response that is not what Elorus documents" do
    test "is an error, not a crash" do
      for body <- [
            "<html>maintenance</html>",
            [],
            %{"detail" => "ok"},
            %{"results" => nil},
            %{"results" => ["not an invoice"]}
          ] do
        Req.Test.stub(Elorus, fn conn -> Req.Test.json(conn, body) end)
        assert Elorus.list_invoices() == {:error, :invalid_response}
      end

      Req.Test.stub(Elorus, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      assert Elorus.list_invoices() == {:error, :invalid_response}
    end

    test "is an error for a single invoice too" do
      Req.Test.stub(Elorus, fn conn -> Req.Test.json(conn, [1, 2]) end)
      assert Elorus.get_invoice("1") == {:error, :invalid_response}

      Req.Test.stub(Elorus, fn conn -> Plug.Conn.send_resp(conn, 200, "<html></html>") end)
      assert Elorus.get_invoice("1") == {:error, :invalid_response}
    end
  end

  describe "list_all_invoices/2" do
    defp stub_pages(pages) do
      test = self()

      Req.Test.stub(Elorus, fn conn ->
        send(test, {:request, conn})
        page = conn |> Plug.Conn.fetch_query_params() |> then(& &1.query_params["page"])
        results = Map.fetch!(pages, String.to_integer(page))
        next = if Map.has_key?(pages, String.to_integer(page) + 1), do: "https://x/?page=next"

        Req.Test.json(conn, page_json(results, next))
      end)
    end

    test "reads the pages until the last one, 250 at a time" do
      stub_pages(%{
        1 => [invoice_json(%{"id" => "1"})],
        2 => [invoice_json(%{"id" => "2"})],
        3 => [invoice_json(%{"id" => "3"})]
      })

      assert {:ok, invoices} = Elorus.list_all_invoices(period: "last_month")

      assert Enum.map(invoices, & &1.id) == ["1", "2", "3"]

      for page <- ~w(1 2 3) do
        assert_received {:request, conn}
        params = Plug.Conn.fetch_query_params(conn).query_params
        assert %{"page" => ^page, "page_size" => "250", "period" => "last_month"} = params
      end

      refute_received {:request, _}
    end

    test "is one request when everything fits on a page" do
      stub_pages(%{1 => []})

      assert Elorus.list_all_invoices() == {:ok, []}
      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "fails rather than return a partial list when there are too many pages" do
      stub_pages(Map.new(1..5, &{&1, [invoice_json(%{"id" => "#{&1}"})]}))

      assert Elorus.list_all_invoices([], max_pages: 3) == {:error, :too_many_pages}

      for _ <- 1..3, do: assert_received({:request, _})
      refute_received {:request, _}
    end

    test "returns the error of a page" do
      Req.Test.stub(Elorus, fn conn ->
        Plug.Conn.send_resp(conn, 403, ~s({"detail": "no"}))
      end)

      assert Elorus.list_all_invoices() == {:error, :forbidden}
    end
  end

  describe "get_invoice/1" do
    test "returns the invoice" do
      stub_json(invoice_json(%{"items" => [%{"title" => "Consulting"}]}))

      assert {:ok, %Invoice{id: "1050000300010040", raw: %{"items" => [_]}}} =
               Elorus.get_invoice("1050000300010040")

      assert_received {:request, conn}
      assert conn.request_path == "/v1.2/invoices/1050000300010040/"
    end

    test "refuses an id that is not a plain id, without a request" do
      Req.Test.stub(Elorus, fn _conn -> flunk("no request should be made") end)

      for id <- ["", ".", "..", "1/../2", "1?x=1", "1#x", "a b", "1\n", "../pdf"] do
        assert Elorus.get_invoice(id) == {:error, :invalid_id}
        assert Elorus.invoice_pdf(id) == {:error, :invalid_id}
      end
    end

    test "takes the ids Elorus uses" do
      stub_json(invoice_json())

      for id <- ["1050000300010040", "abc_DEF-12"] do
        assert {:ok, _} = Elorus.get_invoice(id)
        assert_received {:request, conn}
        assert conn.request_path == "/v1.2/invoices/#{id}/"
      end
    end
  end

  describe "invoice_pdf/1" do
    @pdf "%PDF-1.4\n" <> <<0, 255, 128>> <> "\n%%EOF"

    defp stub_pdf(status \\ 200, body \\ @pdf, content_type \\ "application/pdf") do
      test = self()

      Req.Test.stub(Elorus, fn conn ->
        send(test, {:request, conn})

        conn
        |> Plug.Conn.put_resp_content_type(content_type)
        |> Plug.Conn.send_resp(status, body)
      end)
    end

    test "returns the file as it is" do
      stub_pdf()

      assert Elorus.invoice_pdf("1050000300010040") == {:ok, @pdf}

      assert_received {:request, conn}
      assert conn.request_path == "/v1.2/invoices/1050000300010040/pdf/"
      assert header(conn, "authorization") == "Token test-elorus-token"
      assert header(conn, "x-elorus-organization") == "1000000243015421"
    end

    test "refuses what is not a PDF" do
      stub_pdf(200, "<html>login</html>", "text/html")
      assert Elorus.invoice_pdf("1") == {:error, :invalid_response}

      stub_pdf(200, ~s({"detail": "ok"}), "application/json")
      assert Elorus.invoice_pdf("1") == {:error, :invalid_response}
    end

    test "reports errors like the other calls do" do
      stub_pdf(404, ~s({"detail": "Not found."}), "application/json")
      assert Elorus.invoice_pdf("1") == {:error, :not_found}

      stub_pdf(403, ~s({"detail": "no"}), "application/json")
      assert Elorus.invoice_pdf("1") == {:error, :forbidden}

      stub_pdf(400, ~s({"detail": "bad"}), "application/json")

      assert Elorus.invoice_pdf("1") ==
               {:error, {:unexpected_status, 400, %{"detail" => "bad"}}}

      stub_pdf(
        429,
        ~s({"detail": "Request was throttled. Expected available in 42.0 seconds."}),
        "application/json"
      )

      assert Elorus.invoice_pdf("1") == {:error, {:rate_limited, 42}}
    end
  end

  describe "errors" do
    test "a refused API key" do
      stub_json(%{"detail" => "Invalid token."}, 401)
      assert Elorus.get_invoice("1") == {:error, :unauthorized}
    end

    test "a forbidden action" do
      stub_json(%{"detail" => "You do not have permission."}, 403)
      assert Elorus.get_invoice("1") == {:error, :forbidden}
    end

    test "an unknown invoice" do
      stub_json(%{"detail" => "Not found."}, 404)
      assert Elorus.get_invoice("1") == {:error, :not_found}
    end

    test "a validation error comes back with its body" do
      stub_json(%{"period_from" => ["Enter a valid date."]}, 400)

      assert Elorus.list_invoices(period_from: "x") ==
               {:error, {:unexpected_status, 400, %{"period_from" => ["Enter a valid date."]}}}
    end

    test "throttling says how long to wait, and is not retried" do
      counter = :counters.new(1, [])

      Req.Test.stub(Elorus, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "detail" => "Request was throttled. Expected available in 60.0 seconds."
        })
      end)

      assert Elorus.list_invoices() == {:error, {:rate_limited, 60}}
      assert :counters.get(counter, 1) == 1
    end

    test "throttling with a Retry-After header" do
      Req.Test.stub(Elorus, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "17")
        |> Plug.Conn.send_resp(429, "")
      end)

      assert Elorus.list_invoices() == {:error, {:rate_limited, 17}}
    end

    test "throttling without a hint" do
      stub_json(%{"detail" => "Slow down."}, 429)
      assert Elorus.list_invoices() == {:error, {:rate_limited, nil}}
    end

    test "a server error is retried, and the request can then succeed" do
      counter = :counters.new(1, [])

      Req.Test.stub(Elorus, fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) < 3 do
          Plug.Conn.send_resp(conn, 503, "unavailable")
        else
          Req.Test.json(conn, page_json([invoice_json()]))
        end
      end)

      assert {:ok, %{invoices: [_]}} = Elorus.list_invoices()
      assert :counters.get(counter, 1) == 3
    end

    test "a server error that lasts is reported after two retries" do
      counter = :counters.new(1, [])

      Req.Test.stub(Elorus, fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert Elorus.list_invoices() == {:error, {:unexpected_status, 500, "boom"}}
      assert :counters.get(counter, 1) == 3
    end

    test "a connection error is returned as the exception" do
      Req.Test.stub(Elorus, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Elorus.list_invoices()
    end

    test "a redirect is not followed" do
      counter = :counters.new(1, [])

      Req.Test.stub(Elorus, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/steal")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:unexpected_status, 302, _}} = Elorus.list_invoices()
      assert :counters.get(counter, 1) == 1
    end

    test "a Retry-After on a server error does not hold the caller up" do
      # The delays of the client itself, not the 1 ms of the other tests
      put_config(req_options: [plug: {Req.Test, Elorus}])
      counter = :counters.new(1, [])

      Req.Test.stub(Elorus, fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "3600")
          |> Plug.Conn.send_resp(503, "unavailable")
        else
          Req.Test.json(conn, page_json([]))
        end
      end)

      {microseconds, result} = :timer.tc(fn -> Elorus.list_invoices() end)

      assert {:ok, _} = result
      assert :counters.get(counter, 1) == 2
      assert microseconds < 5_000_000
    end

    test "requests and responses are logged at the debug level, without the API key" do
      Logger.put_module_level(Elorus, :debug)
      on_exit(fn -> Logger.delete_module_level(Elorus) end)

      Req.Test.stub(Elorus, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          Elorus.list_invoices(search: "Acme", period: "last_month")
        end)

      # 1 attempt and 2 retries, and the response that was finally returned
      assert length(Regex.scan(~r{Elorus GET https://api\.elorus\.com/v1\.2/invoices/\?}, log)) ==
               3

      assert log =~ "search=Acme"
      assert log =~ "period=last_month"
      assert log =~ "ordering=-date%2C-created"
      assert log =~ ~r{Elorus GET /v1\.2/invoices/ -> 503 \(\d+ ms\)}
      refute log =~ "test-elorus-token"
      refute log =~ "1000000243015421"
    end

    test "a failed connection is logged too" do
      Logger.put_module_level(Elorus, :debug)
      on_exit(fn -> Logger.delete_module_level(Elorus) end)

      Req.Test.stub(Elorus, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn -> Elorus.get_invoice("1") end)

      assert log =~ ~r{Elorus GET /v1\.2/invoices/1/ failed: .*\(\d+ ms\)}
    end

    test "the API key stays out of every kind of error, and of the log" do
      responses = [
        fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end,
        fn conn -> Plug.Conn.send_resp(conn, 400, ~s({"detail": "bad"})) end,
        fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end,
        fn conn -> Plug.Conn.send_resp(conn, 200, "<html></html>") end,
        fn conn -> Req.Test.transport_error(conn, :timeout) end
      ]

      for respond <- responses do
        Req.Test.stub(Elorus, respond)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            result = Elorus.list_invoices()
            send(self(), {:result, result})
          end)

        assert_received {:result, {:error, _} = result}
        refute inspect(result, limit: :infinity, structs: false) =~ "test-elorus-token"
        refute log =~ "test-elorus-token"
      end
    end
  end
end
