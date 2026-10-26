defmodule IkeEmails.InvoiceExtractor.Client.ReqLLMTest do
  # Not async: it changes the settings and the environment
  use ExUnit.Case, async: false

  import IkeEmails.Fixtures, only: [pdf_fixture: 0]

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
      Keyword.put(settings, :req_http_options, plug: plug, retry: false)
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
  end

  test "maps an answer that is not the object" do
    answer(200, message("I cannot read this."))

    assert {:error, reason} =
             Client.generate(pdf_fixture(), "Read it.", @fields, "anthropic:claude-sonnet-5-5")

    assert reason == :invalid_response
  end
end
