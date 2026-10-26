defmodule IkeEmails.InvoiceExtractor.Client.ReqLLM do
  @moduledoc """
  Reads the PDF through `ReqLLM`, which speaks to Anthropic, OpenAI, Google and
  many more. The provider and the model come from the model string, and ReqLLM
  finds the provider's API key in its own environment variable, such as
  `ANTHROPIC_API_KEY`.
  """

  @behaviour IkeEmails.InvoiceExtractor.Client

  require Logger

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

    with {:ok, response} <- ReqLLM.generate_object(model, messages, schema(fields), options),
         %{} = object <- ReqLLM.Response.object(response) do
      {:ok, object}
    else
      nil -> {:error, :invalid_response}
      {:error, error} -> {:error, reason(error)}
    end
  rescue
    # ReqLLM raises, instead of returning an error, when it finds no API key
    error in ReqLLM.Error.Invalid.Parameter -> {:error, reason(error)}
  end

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
