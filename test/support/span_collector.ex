defmodule IkeEmails.SpanCollector do
  @moduledoc """
  Sends the spans that end in a test to the test, to assert on them. The exporter
  is global, so the tests that use it are not async.

      setup :collect_spans
      ...
      [span] = await_spans(1)
  """

  import ExUnit.Assertions

  require Record

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  @doc """
  The setup that makes this test the receiver of the spans.
  """
  def collect_spans(_context) do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  @doc """
  The next `count` spans that end, oldest first, as maps with `:name`, `:kind`,
  `:attributes`, `:events`, `:span_id` and `:parent_span_id`. Fails if there are
  fewer, and if there are more.
  """
  def await_spans(count) do
    spans =
      for _ <- 1..count do
        assert_receive {:span, record}, 2_000
        decode(record)
      end

    refute_receive {:span, _}, 100, "more spans than the #{count} expected"
    Enum.sort_by(spans, & &1.start_time)
  end

  defp decode(record) do
    span(
      name: name,
      kind: kind,
      attributes: attributes,
      events: events,
      span_id: span_id,
      parent_span_id: parent_span_id,
      start_time: start_time
    ) = record

    %{
      name: name,
      kind: kind,
      attributes: :otel_attributes.map(attributes),
      events: :otel_events.list(events),
      span_id: span_id,
      parent_span_id: parent_span_id,
      start_time: start_time
    }
  end

  @doc """
  Everything a span would send, as one string, to look for what must not be in it.
  """
  def everything(spans), do: inspect(spans, limit: :infinity, printable_limit: :infinity)
end
