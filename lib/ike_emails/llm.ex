defmodule IkeEmails.LLM do
  @moduledoc """
  What the callers of `ReqLLM` share: the attributes of the span of a call, and
  its errors as the rest of the app knows them.

  The attributes hold only what is safe to send to Sentry, see `IkeEmails.Tracing`:
  not the prompt, nor what the model answered.
  """

  require Logger

  @doc """
  Runs a call of ReqLLM, which raises, instead of returning an error, when it
  finds no API key.
  """
  def call(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in ReqLLM.Error.Invalid.Parameter -> {:error, error}
  end

  @doc """
  The attributes of the span of a call, before it is made.
  """
  def request_attributes(model, max_tokens) do
    {provider, name} = split_model(model)

    %{
      "gen_ai.operation.name" => "chat",
      "gen_ai.provider.name" => provider,
      "gen_ai.request.model" => name,
      "gen_ai.request.max_tokens" => max_tokens
    }
  end

  @doc """
  The attributes of the span of a call that ended with `result`, which the caller
  answers with `reply`.

  Sentry shows a call only with the model that answered. A call that failed has
  none, so it has the one that was asked for.
  """
  def response_attributes(result, reply, model) do
    {_provider, name} = split_model(model)

    Map.merge(
      %{
        "gen_ai.response.model" => response_model(result) || name,
        "error.type" => error_type(reply)
      },
      usage_attributes(result)
    )
  end

  @doc """
  The provider of a model such as `anthropic:claude-sonnet-5-5`, or `nil`.
  """
  def provider(model), do: model |> split_model() |> elem(0)

  @doc """
  An error of ReqLLM as `:unauthorized`, `:rate_limited`, `:timeout`,
  `:invalid_response`, `:missing_key` or `{:failed, message}`.
  """
  def reason(%ReqLLM.Error.API.Request{status: status}) when status in [401, 403],
    do: :unauthorized

  def reason(%ReqLLM.Error.API.Request{status: 429}), do: :rate_limited
  def reason(%ReqLLM.Error.API.Timeout{}), do: :timeout
  def reason(%ReqLLM.Error.API.SchemaValidation{}), do: :invalid_response
  def reason(%ReqLLM.Error.API.JSONDecode{}), do: :invalid_response
  def reason(%ReqLLM.Error.API.Response{}), do: :invalid_response

  def reason(%ReqLLM.Error.Invalid.Parameter{} = error) do
    message = Exception.message(error)
    if message =~ "api_key", do: :missing_key, else: {:failed, message}
  end

  def reason(error) do
    message = Exception.message(error)
    Logger.warning("A call to the language model failed: #{message}")
    {:failed, message}
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
  defp error_type({:ok, _answer}), do: nil
  defp error_type({:error, {:failed, _message}}), do: "failed"
  defp error_type({:error, reason}), do: to_string(reason)
end
