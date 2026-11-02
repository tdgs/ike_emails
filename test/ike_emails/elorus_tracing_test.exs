defmodule IkeEmails.ElorusTracingTest do
  # Not async: the spans go to one receiver, and some tests change the configuration
  use ExUnit.Case, async: false

  # The retries are logged
  @moduletag :capture_log

  import IkeEmails.SpanCollector

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Accounts.User
  alias IkeEmails.Elorus
  alias IkeEmails.Elorus.Connection
  alias IkeEmails.Elorus.Credentials
  alias IkeEmails.ElorusStub
  alias IkeEmails.Tracing

  setup :collect_spans

  @credentials %Credentials{api_token: "test-elorus-token", organization_id: "1000000243015421"}

  # An id that must never be seen in a span
  @invoice_id "abc123"

  describe "a request" do
    test "is one span, as a request to Elorus" do
      ElorusStub.stub()

      assert {:ok, _pdf} = Elorus.invoice_pdf(@credentials, @invoice_id)

      assert [span] = await_spans(1)
      assert span.name == "elorus GET /v1.2/invoices/:id/pdf/"
      # Sentry shows a client span with these as an HTTP request
      assert span.kind == :client

      assert span.attributes == %{
               "http.request.method" => "GET",
               "url.path" => "/v1.2/invoices/:id/pdf/",
               "server.address" => "api.elorus.com",
               "http.response.status_code" => 200
             }
    end

    test "has the template of the path, and not the id of the invoice" do
      ElorusStub.stub()

      assert {:ok, _pdf} = Elorus.invoice_pdf(@credentials, @invoice_id)

      spans = await_spans(1)
      refute everything(spans) =~ @invoice_id
    end

    test "has the status of an answer that is an error" do
      ElorusStub.stub(status: 404)

      assert {:error, :not_found} = Elorus.invoice_pdf(@credentials, @invoice_id)

      assert [span] = await_spans(1)
      assert span.attributes["http.response.status_code"] == 404
      refute Map.has_key?(span.attributes, "error.type")
    end

    test "is one span for the request and its retries" do
      ElorusStub.stub(status: 503)

      assert {:error, {:unexpected_status, 503, _body}} =
               Elorus.invoice_pdf(@credentials, @invoice_id)

      # The request and the two retries
      for _ <- 1..3, do: assert_received({:elorus_request, _conn})
      refute_received {:elorus_request, _conn}

      assert [span] = await_spans(1)
      assert span.attributes["http.response.status_code"] == 503
    end

    test "has the kind of the error when the request itself fails" do
      Req.Test.stub(Elorus, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{}} = Elorus.invoice_pdf(@credentials, @invoice_id)

      assert [span] = await_spans(1)
      assert span.attributes["error.type"] == "Req.TransportError"
      refute Map.has_key?(span.attributes, "http.response.status_code")
    end

    test "is not made without credentials" do
      credentials = %{@credentials | api_token: nil}

      assert {:error, :not_configured} = Elorus.invoice_pdf(credentials, @invoice_id)
      assert {:error, :not_configured} = Elorus.list_all_invoices(credentials)

      refute_receive {:span, _}, 200
    end

    test "is not made for an id that is not valid" do
      assert {:error, :invalid_id} = Elorus.invoice_pdf(@credentials, "../secrets")

      refute_receive {:span, _}, 200
    end

    test "does not carry the credentials, the query or what is answered" do
      ElorusStub.stub(invoices: [ElorusStub.invoice_json()])

      assert {:ok, [_invoice]} =
               Elorus.list_all_invoices(@credentials, client: "a-client-id-from-the-query")

      everything = everything(await_spans(2))
      refute everything =~ "test-elorus-token"
      refute everything =~ "1000000243015421"
      refute everything =~ "a-client-id-from-the-query"
      refute everything =~ "Acme"
    end
  end

  describe "list_all_invoices/2" do
    test "has the requests of its pages in one span" do
      Req.Test.stub(Elorus, fn conn ->
        next = if conn.query_params["page"] == "1", do: "https://api.elorus.com/next", else: nil

        Req.Test.json(conn, %{
          "count" => 2,
          "next" => next,
          "previous" => nil,
          "results" => [ElorusStub.invoice_json()]
        })
      end)

      assert {:ok, [_one, _two]} = Elorus.list_all_invoices(@credentials)

      assert [parent, first, second] = await_spans(3)
      assert parent.name == "elorus list_all_invoices"
      assert parent.kind == :internal
      assert parent.parent_span_id in [nil, :undefined]
      assert first.parent_span_id == parent.span_id
      assert second.parent_span_id == parent.span_id
      assert first.name == "elorus GET /v1.2/invoices/"
    end
  end

  describe "a request through the connection" do
    setup do
      # The requests are made by the process of the connection, not by the test
      :ok = Req.Test.set_req_test_to_shared()

      scope = Scope.for_user(%User{id: System.unique_integer([:positive])})
      :ok = Connection.put_credentials(scope, @credentials)
      on_exit(fn -> Connection.lock(scope) end)

      %{scope: scope}
    end

    test "has its spans inside the span of the caller", %{scope: scope} do
      ElorusStub.stub(invoices: [ElorusStub.invoice_json()])

      Tracing.span("a caller", %{}, fn ->
        assert {:ok, [_invoice]} = Connection.list_all_invoices(scope)
      end)

      assert [caller, list, request] = await_spans(3)
      assert caller.name == "a caller"
      assert list.name == "elorus list_all_invoices"
      assert request.name == "elorus GET /v1.2/invoices/"
      assert list.parent_span_id == caller.span_id
      assert request.parent_span_id == list.span_id
    end

    test "has spans of its own, without a caller that has one", %{scope: scope} do
      ElorusStub.stub()

      assert {:ok, _pdf} = Connection.invoice_pdf(scope, @invoice_id)

      assert [span] = await_spans(1)
      assert span.name == "elorus GET /v1.2/invoices/:id/pdf/"
      assert span.parent_span_id in [nil, :undefined]
    end

    test "does not carry the credentials", %{scope: scope} do
      ElorusStub.stub(invoices: [ElorusStub.invoice_json()])

      assert {:ok, [_invoice]} = Connection.list_all_invoices(scope)

      everything = everything(await_spans(2))
      refute everything =~ "test-elorus-token"
      refute everything =~ "1000000243015421"
    end
  end
end
