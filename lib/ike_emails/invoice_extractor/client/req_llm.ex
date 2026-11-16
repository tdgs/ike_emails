defmodule IkeEmails.InvoiceExtractor.Client.ReqLLM do
  @moduledoc """
  Reads the PDF through `ReqLLM`, which speaks to Anthropic, OpenAI, Google and
  many more. The provider and the model come from the model string, and ReqLLM
  finds the provider's API key in its own environment variable, such as
  `ANTHROPIC_API_KEY`.
  """

  @behaviour IkeEmails.InvoiceExtractor.Client

  require Logger

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

    # No retries: ReqLLM retries 3 times by default, so one answer slower than the
    # timeout would be sent, and paid for, four times
    options = [
      max_tokens: @max_tokens,
      receive_timeout: @receive_timeout,
      max_retries: 0,
      req_http_options: http_options()
    ]

    # The span is named for the operation, which Sentry takes as the type of the
    # span, and shows in its view of the language models. The model is in the
    # attributes. What is sent in them is only what is safe, see IkeEmails.Tracing:
    # not the prompt, the PDF or what is read from it
    Tracing.span("gen_ai.chat", request_attributes(model, pdf), :client, fn ->
      result = generate_object(model, messages, schema(fields), options)
      reply = reply(result)

      Tracing.set_attributes(response_attributes(result, reply, model))
      reply
    end)
  end

  # ReqLLM raises, instead of returning an error, when it finds no API key
  defp generate_object(model, messages, schema, options) do
    ReqLLM.generate_object(model, messages, schema, options)
  rescue
    error in ReqLLM.Error.Invalid.Parameter -> {:error, error}
  end

  defp reply({:ok, response}) do
    case ReqLLM.Response.object(response) do
      %{} = object -> {:ok, object}
      nil -> {:error, :invalid_response}
    end
  end

  defp reply({:error, error}), do: {:error, reason(error)}

  defp request_attributes(model, pdf) do
    {provider, name} = split_model(model)

    %{
      "gen_ai.operation.name" => "chat",
      "gen_ai.provider.name" => provider,
      "gen_ai.request.model" => name,
      "gen_ai.request.max_tokens" => @max_tokens,
      "ike_emails.pdf_bytes" => byte_size(pdf)
    }
  end

  # Sentry shows a call only with the model that answered. A call that failed has
  # none, so it has the one that was asked for
  defp response_attributes(result, reply, model) do
    {_provider, name} = split_model(model)

    Map.merge(
      %{
        "gen_ai.response.model" => response_model(result) || name,
        "error.type" => error_type(reply)
      },
      usage_attributes(result)
    )
  end

  defp response_model({:ok, %ReqLLM.Response{model: model}}) when is_binary(model), do: model
  defp response_model(_result), do: nil

  defp usage_attributes({:ok, %ReqLLM.Response{} = response}) do
    usage = ReqLLM.Response.usage(response) || %{}

    %{
      "gen_ai.response.finish_reasons" => finish_reasons(ReqLLM.Response.finish_reason(response)),
      "gen_ai.usage.input_tokens" => count(usage[:input_tokens]),
      "gen_ai.usage.output_tokens" => count(usage[:output_tokens]),
      "gen_ai.usage.total_tokens" => count(usage[:total_tokens])
    }
  end

  defp usage_attributes(_result), do: %{}

  defp finish_reasons(nil), do: nil
  defp finish_reasons(reason), do: [to_string(reason)]

  defp count(value) when is_number(value), do: value
  defp count(_value), do: nil

  # "anthropic:claude-sonnet-5-5" is the provider and the model
  defp split_model(model) do
    case String.split(model, ":", parts: 2) do
      [provider, name] -> {provider, name}
      [name] -> {nil, name}
    end
  end

  # The kind of the error and nothing of its message, which can carry what the
  # provider answered
  defp error_type({:ok, _object}), do: nil
  defp error_type({:error, {:failed, _message}}), do: "failed"
  defp error_type({:error, reason}), do: to_string(reason)

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

  defp reason(%ReqLLM.Error.API.Request{status: status}) when status in [401, 403],
    do: :unauthorized

  defp reason(%ReqLLM.Error.API.Request{status: 429}), do: :rate_limited
  defp reason(%ReqLLM.Error.API.Timeout{}), do: :timeout

  # A receive timeout comes from Req as a transport error inside the error of the request
  defp reason(%ReqLLM.Error.API.Request{cause: %Req.TransportError{reason: :timeout}}),
    do: :timeout

  defp reason(%ReqLLM.Error.API.SchemaValidation{}), do: :invalid_response
  defp reason(%ReqLLM.Error.API.JSONDecode{}), do: :invalid_response
  defp reason(%ReqLLM.Error.API.Response{}), do: :invalid_response

  defp reason(%ReqLLM.Error.Invalid.Parameter{} = error) do
    message = Exception.message(error)
    if message =~ "api_key", do: :missing_key, else: {:failed, message}
  end

  defp reason(error) do
    message = Exception.message(error)
    Logger.warning("Reading an invoice with AI failed: #{message}")
    {:failed, message}
  end
end
