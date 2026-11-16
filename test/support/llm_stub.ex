defmodule IkeEmails.LLMStub do
  @moduledoc """
  Answers the requests of the month-close agent to the language model in the
  tests, as Anthropic would. Every request is sent to the test as
  `{:llm_request, body}`.

  It changes the configuration of the application, so the tests cannot be async.
  """

  @doc """
  Answers the requests with `replies`, one after the other, and goes on with the
  last one when they are used up. A reply is a body (see `tool_use/1` and
  `text/1`) or `{status, body}`.
  """
  def script(replies) when replies != [] do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> replies end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:llm_request, Jason.decode!(body)})

      {status, reply} =
        case Agent.get_and_update(agent, &next/1) do
          {status, reply} -> {status, reply}
          reply -> {200, reply}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(reply))
    end

    settings = Application.fetch_env!(:ike_emails, IkeEmails.MonthClose)
    key = System.get_env("ANTHROPIC_API_KEY")

    Application.put_env(
      :ike_emails,
      IkeEmails.MonthClose,
      Keyword.put(settings, :req_http_options, plug: plug, retry: false)
    )

    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ike_emails, IkeEmails.MonthClose, settings)

      if key,
        do: System.put_env("ANTHROPIC_API_KEY", key),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    :ok
  end

  defp next([last]), do: {last, [last]}
  defp next([reply | rest]), do: {reply, rest}

  @doc """
  The model asks for tools: `calls` are `{name, arguments}`.
  """
  def tool_use(calls) do
    content =
      Enum.map(calls, fn {name, arguments} ->
        %{
          "type" => "tool_use",
          "id" => "toolu_#{System.unique_integer([:positive])}",
          "name" => name,
          "input" => arguments
        }
      end)

    message(content, "tool_use")
  end

  @doc """
  The model is done, and says `text`.
  """
  def text(text \\ "Done."), do: message([%{"type" => "text", "text" => text}], "end_turn")

  defp message(content, stop_reason) do
    %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-5-5",
      "content" => content,
      "stop_reason" => stop_reason,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }
  end

  @doc """
  What the tools answered in a request, as `{decoded content, error?}` in the
  order of the calls.
  """
  def tool_results(%{"messages" => messages}) do
    for %{"role" => "user", "content" => parts} <- messages,
        is_list(parts),
        %{"type" => "tool_result"} = part <- parts do
      {part |> result_text() |> Jason.decode!(), part["is_error"] == true}
    end
  end

  defp result_text(%{"content" => text}) when is_binary(text), do: text
  defp result_text(%{"content" => [%{"text" => text} | _]}), do: text
end
