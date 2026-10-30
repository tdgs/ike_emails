defmodule IkeEmails.Tracing do
  @moduledoc """
  Spans for the calls to the services outside, Elorus and the language model.
  They are made with OpenTelemetry, which Sentry turns into traces when
  `SENTRY_DSN` is set (`config/runtime.exs`), and are dropped without it.

  Sentry does not scrub what a span holds, and the calls carry the API keys, the
  PDF of an invoice and what is read from it. So a span gets only the attributes
  that the caller lists, each of them safe to send: a method, the template of a
  path, a status, a model, a count of tokens. Never a header, a URL with its id, a
  body, the prompt or an error message.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Runs `fun` in a span and returns what it returns. The span ends, and an error
  that `fun` raises is raised again.

  `kind` is `:client` for a call to another service, which is what makes Sentry
  show the span of a request as an HTTP request.
  """
  def span(name, attributes, kind \\ :internal, fun)
      when is_binary(name) and is_function(fun, 0) do
    Tracer.with_span name, %{kind: kind, attributes: normalize(attributes)} do
      fun.()
    end
  end

  @doc """
  Adds attributes to the current span.
  """
  def set_attributes(attributes) do
    Tracer.set_attributes(normalize(attributes))
  end

  # OpenTelemetry takes no nil, and Sentry shows an atom as it is inspected
  defp normalize(attributes) do
    for {key, value} <- attributes, not is_nil(value), into: %{} do
      {to_string(key), value(value)}
    end
  end

  defp value(value) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp value(value), do: value
end
