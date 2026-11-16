defmodule IkeEmails.InvoiceExtractor.Client.ReqLLMTest do
  # Not async: it changes the settings and the environment
  use ExUnit.Case, async: false

  import IkeEmails.Fixtures, only: [pdf_fixture: 0]
  import IkeEmails.SpanCollector

  alias IkeEmails.InvoiceExtractor
  alias IkeEmails.InvoiceExtractor.Client.ReqLLM, as: Client

  @fields [
    amount: "The total.",
    currency: "The currency.",
    issuer_name: "The issuer."
  ]

  @found ~s({"amount":"12.50","currency":"EUR","issuer_name":null})

  setup do
    settings = Application.fetch_env!(:ike_emails, InvoiceExtractor)
    key = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")

    on_exit(fn ->
      Application.put_env(:ike_emails, InvoiceExtractor, settings)

      if key,
        do: System.put_env("ANTHROPIC_API_KEY", key),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    :ok
  end

  # Answers the request of the client, and sends it to the test
  defp answer(status, body) do
    test = self()

    plug = fn conn ->
      {:ok, request, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, Jason.decode!(request)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end

    settings = Application.fetch_env!(:ike_emails, InvoiceExtractor)

    Application.put_env(
      :ike_emails,
      InvoiceExtractor,
      Keyword.put(settings, :req_http_options, plug: plug)
    )
  end

  defp message(text) do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-5-5",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }
  end

  test "sends the PDF and the schema, and returns the fields that were found" do
    pdf = pdf_fixture()
    answer(200, message(@found))

    assert Client.generate(pdf, "Read it.", @fields, "anthropic:claude-sonnet-5-5") ==
             {:ok, %{"amount" => "12.50", "currency" => "EUR", "issuer_name" => nil}}

    assert_receive {:request, conn, body}
    assert conn.request_path == "/v1/messages"
    assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]
    assert body["model"] == "claude-sonnet-5-5"
    assert body["max_tokens"] == 1024

    assert [%{"role" => "user", "content" => [text, document]}] = body["messages"]
    assert text == %{"type" => "text", "text" => "Read it."}
    assert document["type"] == "document"

    assert document["source"] == %{
             "type" => "base64",
             "media_type" => "application/pdf",
             "data" => Base.encode64(pdf)
           }

    schema = body["output_format"]["schema"]
    assert Enum.sort(schema["required"]) == ~w(amount currency issuer_name)
    assert %{"anyOf" => options} = schema["properties"]["amount"]
    assert %{"type" => "null"} in options
  end

  test "maps a missing key" do
    System.delete_env("ANTHROPIC_API_KEY")

    assert Client.generate(pdf_fixture(), "Read it.", @fields, "anthropic:claude-sonnet-5-5") ==
             {:error, :missing_key}
  end

  test "maps a rejected key" do
    answer(401, %{
      "type" => "error",
      "error" => %{"type" => "authentication_error", "message" => "no"}
    })

    assert Client.generate(pdf_fixture(), "Read it.", @fields, "anthropic:claude-sonnet-5-5") ==
             {:error, :unauthorized}
  end

  test "maps a rate limit" do
    answer(429, %{
      "type" => "error",
      "error" => %{"type" => "rate_limit_error", "message" => "slow"}
    })

    assert Client.generate(pdf_fixture(), "Read it.", @fields, "anthropic:claude-sonnet-5-5") ==
             {:error, :rate_limited}

    # Sent once: every retry of ReqLLM would be another call that is paid for
    assert_received {:request, _conn, _body}
    refute_received {:request, _conn, _body}
  end

  test "maps a model that does not answer in time, and asks once" do
    test = self()

    plug = fn conn ->
      send(test, :requested)
      Req.Test.transport_error(conn, :timeout)
    end

    settings = Application.fetch_env!(:ike_emails, InvoiceExtractor)

    Application.put_env(
      :ike_emails,
      InvoiceExtractor,
      Keyword.put(settings, :req_http_options, plug: plug)
    )

    assert Client.generate(pdf_fixture(), "Read it.", @fields, "anthropic:claude-sonnet-5-5") ==
             {:error, :timeout}

    assert_received :requested
    refute_received :requested
  end

  test "maps an answer that is not the object" do
    answer(200, message("I cannot read this."))

    assert {:error, reason} =
             Client.generate(pdf_fixture(), "Read it.", @fields, "anthropic:claude-sonnet-5-5")

    assert reason == :invalid_response
  end

  describe "the span" do
    setup :collect_spans

    @model "anthropic:claude-sonnet-5-5"

    test "is the operation, with the model and what it used" do
      pdf = pdf_fixture()
      answer(200, message(@found))

      assert {:ok, _found} = Client.generate(pdf, "Read it.", @fields, @model)

      assert [span] = await_spans(1)
      # Sentry takes the type of the span from its name
      assert span.name == "gen_ai.chat"
      assert span.kind == :client

      assert span.attributes == %{
               "gen_ai.operation.name" => "chat",
               "gen_ai.provider.name" => "anthropic",
               "gen_ai.request.model" => "claude-sonnet-5-5",
               "gen_ai.request.max_tokens" => 1024,
               "gen_ai.response.model" => "claude-sonnet-5-5",
               "gen_ai.response.finish_reasons" => ["stop"],
               "gen_ai.usage.input_tokens" => 10,
               "gen_ai.usage.output_tokens" => 10,
               "gen_ai.usage.total_tokens" => 20,
               "ike_emails.pdf_bytes" => byte_size(pdf)
             }
    end

    for {name, setup, reason} <- [
          {"a rejected key", {401, %{"type" => "error", "error" => %{"message" => "no"}}},
           "unauthorized"},
          {"a rate limit", {429, %{"type" => "error", "error" => %{"message" => "slow"}}},
           "rate_limited"}
        ] do
      test "has the kind of the error, and the model that was asked for, for #{name}" do
        {status, body} = unquote(Macro.escape(setup))
        answer(status, body)

        assert {:error, _reason} = Client.generate(pdf_fixture(), "Read it.", @fields, @model)

        assert [span] = await_spans(1)
        assert span.attributes["error.type"] == unquote(reason)
        # Without a model of the answer, Sentry would not show the call
        assert span.attributes["gen_ai.response.model"] == "claude-sonnet-5-5"
        refute Map.has_key?(span.attributes, "gen_ai.usage.input_tokens")
      end
    end

    test "has the kind of the error when there is no key, which ReqLLM raises" do
      System.delete_env("ANTHROPIC_API_KEY")

      assert {:error, :missing_key} = Client.generate(pdf_fixture(), "Read it.", @fields, @model)

      assert [span] = await_spans(1)
      assert span.attributes["error.type"] == "missing_key"
      assert span.attributes["gen_ai.response.model"] == "claude-sonnet-5-5"
    end

    test "has the kind of an answer that is not the object, and the tokens it used" do
      answer(200, message("I cannot read this."))

      assert {:error, :invalid_response} =
               Client.generate(pdf_fixture(), "Read it.", @fields, @model)

      assert [span] = await_spans(1)
      assert span.attributes["error.type"] == "invalid_response"
      assert span.attributes["gen_ai.usage.total_tokens"] == 20
    end

    test "carries neither the PDF, the prompt, what was read, nor the key" do
      pdf = pdf_fixture()
      answer(200, message(@found))

      assert {:ok, _found} =
               Client.generate(pdf, "Read the invoice of Acme Ltd.", @fields, @model)

      assert [span] = await_spans(1)
      everything = everything([span])

      refute everything =~ Base.encode64(pdf)
      refute everything =~ "Acme"
      refute everything =~ "12.50"
      refute everything =~ "test-anthropic-key"
      refute Map.has_key?(span.attributes, "gen_ai.input.messages")
      refute Map.has_key?(span.attributes, "gen_ai.output.messages")
      refute Map.has_key?(span.attributes, "gen_ai.system_instructions")
    end
  end
end
