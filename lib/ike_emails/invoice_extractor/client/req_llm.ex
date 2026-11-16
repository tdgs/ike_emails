defmodule IkeEmails.InvoiceExtractor.Client.ReqLLM do
  @moduledoc """
  Reads the PDF through `ReqLLM`, which speaks to Anthropic, OpenAI, Google and
  many more. The provider and the model come from the model string, and ReqLLM
  finds the provider's API key in its own environment variable, such as
  `ANTHROPIC_API_KEY`.
  """

  @behaviour IkeEmails.InvoiceExtractor.Client

  alias IkeEmails.LLM
  alias IkeEmails.Tracing

  @max_tokens 1024
  @receive_timeout 60_000

  @impl true
  def generate(pdf, prompt, fields, model) do
    messages = [
      ReqLLM.Context.user([
        ReqLLM.Message.ContentPart.text(prompt),
        ReqLLM.Message.ContentPart.file(pdf, "invoice.pdf", "application/pdf")
      ])
    ]

    options = [
      max_tokens: @max_tokens,
      receive_timeout: @receive_timeout,
      req_http_options: http_options()
    ]

    # The span is named for the operation, which Sentry takes as the type of the
    # span, and shows in its view of the language models. The model is in the
    # attributes. What is sent in them is only what is safe, see IkeEmails.Tracing:
    # not the prompt, the PDF or what is read from it
    attributes =
      model
      |> LLM.request_attributes(@max_tokens)
      |> Map.put("ike_emails.pdf_bytes", byte_size(pdf))

    Tracing.span("gen_ai.chat", attributes, :client, fn ->
      result =
        LLM.call(fn -> ReqLLM.generate_object(model, messages, schema(fields), options) end)

      reply = reply(result)

      Tracing.set_attributes(LLM.response_attributes(result, reply, model))
      reply
    end)
  end

  defp reply({:ok, response}) do
    case ReqLLM.Response.object(response) do
      %{} = object -> {:ok, object}
      nil -> {:error, :invalid_response}
    end
  end

  defp reply({:error, error}), do: {:error, LLM.reason(error)}

  defp schema(fields) do
    fields
    |> Map.new(fn {name, description} ->
      {name, Zoi.nullable(Zoi.string(description: description))}
    end)
    |> Zoi.object()
  end

  # Lets the tests answer the requests with a Req.Test plug
  defp http_options do
    :ike_emails
    |> Application.get_env(IkeEmails.InvoiceExtractor, [])
    |> Keyword.get(:req_http_options, [])
  end
end
