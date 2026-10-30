defmodule IkeEmails.Elorus do
  @moduledoc """
  Client for the [Elorus API](https://developer.elorus.com) (v1.2), where the
  invoices for income are issued.

  Every call needs the API key of an Elorus user and the id of the organization
  to work on, from the environment (`config/runtime.exs`). Without them the
  calls return `{:error, :not_configured}`, and `configured?/0` tells the UI not
  to offer the integration.

  Results are `{:ok, value}` or `{:error, reason}`, where the reason is one of:

    * `:not_configured` - no API key or organization id
    * `:invalid_id` - the invoice id is not made of letters, digits, `-` and `_`
    * `:unauthorized` - the API key was refused
    * `:forbidden` - the user may not do that in the organization
    * `:not_found`
    * `{:rate_limited, seconds}` - Elorus allows 60 requests a minute and 1000 a
      day per user. `seconds` is how long to wait, `nil` if Elorus did not say.
      The request is not retried, so as not to spend the daily quota.
    * `{:unexpected_status, status, body}`
    * `:invalid_response` - Elorus answered 200 with something else than expected
    * `:too_many_pages` - see `list_all_invoices/2`
    * an exception, when the request itself failed (a timeout, for example)

  A request that fails with a 500, 502, 503 or 504 status, or because of the
  connection, is retried twice, after half a second and after a second. A
  `Retry-After` header is ignored, so that a server cannot hold the caller up.
  Redirects are not followed.

  Each request and its response are logged at the `:debug` level (the method, the
  URL with its query, the status and the time it took), which the development
  console shows. The headers, and so the API key, are never logged.
  """

  require Logger

  alias IkeEmails.Elorus.Invoice
  alias IkeEmails.Tracing

  @max_page_size 250

  # Ties on the date are broken by the creation time, so that a page boundary
  # cannot repeat or skip an invoice
  @default_ordering "-date,-created"

  @type error ::
          :not_configured
          | :invalid_id
          | :unauthorized
          | :forbidden
          | :not_found
          | {:rate_limited, non_neg_integer() | nil}
          | {:unexpected_status, pos_integer(), term()}
          | :invalid_response
          | :too_many_pages
          | Exception.t()

  @doc """
  Whether the API key and the organization id are set.
  """
  def configured?, do: configured?(config())

  defp configured?(config) do
    present?(config[:api_token]) and present?(config[:organization_id])
  end

  @doc """
  One page of invoices, newest first unless `:ordering` says otherwise.

  `params` are the query parameters of the API, as a keyword list. Among them:

    * `:period_from` and `:period_to` - dates, which only work together
    * `:period` - `"current_month"`, `"last_month"`, `"last_3_months"`, ...
    * `:search` and `:client` (an id)
    * `:status` - `"draft"`, `"pending"`, `"issued"`, `"partial"`, `"unpaid"`,
      `"overdue"`, `"paid"` or `"void"`
    * `:draft`, `:fpaid`, `:is_void`, `:overdue` - `true` or `false`
    * `:currency_code`
    * `:ordering` - a field, `"-"` first to reverse it, `"-date,-created"` by default
    * `:page` and `:page_size` - up to 250, 100 by default

  See https://developer.elorus.com/en/#operation/invoices_list for all of them.

  Returns `%{count: total, invoices: [...], more?: another page follows}`. The
  list does not carry everything of an invoice; `get_invoice/1` does.
  """
  def list_invoices(params \\ []) do
    params = params |> Keyword.put_new(:ordering, @default_ordering) |> query_params()

    with {:ok, body} <- get("/v1.2/invoices/", params: params) do
      invoices_page(body)
    end
  end

  # The API takes 1 and 0 for the flags
  defp query_params(params) do
    Enum.map(params, fn
      {key, true} -> {key, "1"}
      {key, false} -> {key, "0"}
      param -> param
    end)
  end

  defp invoices_page(%{"results" => results} = body) when is_list(results) do
    if Enum.all?(results, &is_map/1) do
      {:ok,
       %{
         count: body["count"],
         invoices: Enum.map(results, &Invoice.from_api/1),
         more?: body["next"] != nil
       }}
    else
      {:error, :invalid_response}
    end
  end

  defp invoices_page(_body), do: {:error, :invalid_response}

  @doc """
  All the invoices that match `params`, which take the same filters as
  `list_invoices/1`, read page by page.

  Takes at most `:max_pages` pages (20 by default) of 250 invoices, one request
  each. When there are more, it returns `{:error, :too_many_pages}` and not a
  partial list: narrow the query down, with a period for example.
  """
  def list_all_invoices(params \\ [], opts \\ []) do
    max_pages = Keyword.get(opts, :max_pages, 20)
    params = Keyword.put_new(params, :page_size, @max_page_size)

    read_pages = fn -> collect_pages(Keyword.delete(params, :page), 1, max_pages, []) end

    # The requests of the pages are the spans inside this one. Without a
    # configuration there are no requests, and no span either
    if configured?() do
      Tracing.span("elorus list_all_invoices", %{}, read_pages)
    else
      read_pages.()
    end
  end

  defp collect_pages(_params, page, max_pages, _acc) when page > max_pages do
    {:error, :too_many_pages}
  end

  defp collect_pages(params, page, max_pages, acc) do
    case list_invoices(Keyword.put(params, :page, page)) do
      {:ok, %{invoices: invoices, more?: true}} ->
        collect_pages(params, page + 1, max_pages, [invoices | acc])

      {:ok, %{invoices: invoices, more?: false}} ->
        {:ok, [invoices | acc] |> Enum.reverse() |> Enum.concat()}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  A single invoice, with all of its details in `:raw`.
  """
  def get_invoice(id) when is_binary(id) do
    with :ok <- validate_id(id),
         {:ok, body} <- get("/v1.2/invoices/:id/", path_params: [id: id]) do
      if is_map(body), do: {:ok, Invoice.from_api(body)}, else: {:error, :invalid_response}
    end
  end

  @doc """
  The PDF of an invoice, as a binary.
  """
  def invoice_pdf(id) when is_binary(id) do
    with :ok <- validate_id(id),
         {:ok, body} <- get("/v1.2/invoices/:id/pdf/", path_params: [id: id]) do
      if is_binary(body) and String.starts_with?(body, "%PDF-"),
        do: {:ok, body},
        else: {:error, :invalid_response}
    end
  end

  # The id becomes a segment of the path, where "." and ".." would not be safe
  defp validate_id(id) do
    if String.match?(id, ~r/\A[A-Za-z0-9_-]+\z/), do: :ok, else: {:error, :invalid_id}
  end

  defp get(url, opts) do
    config = config()

    if configured?(config) do
      # One span for the call, with the retries in it. The path in it is `url`, the
      # template, because the resolved one holds the id of an invoice
      Tracing.span("elorus GET #{url}", request_attributes(config, url), :client, fn ->
        result = config |> new_request() |> Req.request([method: :get, url: url] ++ opts)

        Tracing.set_attributes(response_attributes(result))
        handle_response(result)
      end)
    else
      {:error, :not_configured}
    end
  end

  # What is sent in a span, and nothing else: see IkeEmails.Tracing
  defp request_attributes(config, url) do
    %{
      "http.request.method" => "GET",
      "url.path" => url,
      "server.address" => config[:base_url] && URI.parse(config[:base_url]).host
    }
  end

  defp response_attributes({:ok, %Req.Response{status: status}}),
    do: %{"http.response.status_code" => status}

  defp response_attributes({:error, %module{}}), do: %{"error.type" => inspect(module)}
  defp response_attributes({:error, _other}), do: %{"error.type" => "unknown"}

  defp new_request(config) do
    headers =
      [
        authorization: "Token #{config[:api_token]}",
        x_elorus_organization: config[:organization_id]
      ]
      |> then(&if(config[:demo], do: [{:x_elorus_demo, "true"} | &1], else: &1))

    [
      base_url: config[:base_url],
      headers: headers,
      redirect: false,
      retry: &retry?/2,
      retry_delay: &retry_delay/1,
      max_retries: 2,
      receive_timeout: 15_000
    ]
    |> Req.new()
    |> Req.Request.append_request_steps(log_request: &log_request/1)
    |> Req.Request.append_response_steps(log_response: &log_response/1)
    |> Req.Request.append_error_steps(log_error: &log_error/1)
    |> Req.merge(config[:req_options] || [])
  end

  # A retry runs the steps again, so every attempt is logged
  defp log_request(request) do
    Logger.debug(fn -> "Elorus #{method(request)} #{URI.to_string(request.url)}" end)
    Req.Request.put_private(request, :elorus_started_at, System.monotonic_time())
  end

  defp log_response({request, response}) do
    Logger.debug(fn ->
      "Elorus #{method(request)} #{request.url.path} -> #{response.status} #{elapsed(request)}"
    end)

    {request, response}
  end

  defp log_error({request, exception}) do
    Logger.debug(fn ->
      "Elorus #{method(request)} #{request.url.path} failed: " <>
        "#{Exception.message(exception)} #{elapsed(request)}"
    end)

    {request, exception}
  end

  defp method(request), do: request.method |> to_string() |> String.upcase()

  defp elapsed(request) do
    started_at = Req.Request.get_private(request, :elorus_started_at, System.monotonic_time())
    ms = System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
    "(#{ms} ms)"
  end

  # Not a 429, which would only use up the daily quota
  defp retry?(_request, %Req.Response{status: status}), do: status in [500, 502, 503, 504]
  defp retry?(_request, %Req.TransportError{}), do: true
  defp retry?(_request, _exception), do: false

  defp retry_delay(attempt), do: 500 * Integer.pow(2, attempt)

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}
  defp handle_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp handle_response({:ok, %Req.Response{status: 403}}), do: {:error, :forbidden}
  defp handle_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}

  defp handle_response({:ok, %Req.Response{status: 429} = response}) do
    {:error, {:rate_limited, retry_after(response)}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:unexpected_status, status, body}}
  end

  defp handle_response({:error, exception}), do: {:error, exception}

  # The Retry-After header, or else the message "Request was throttled. Expected
  # available in 60.0 seconds."
  defp retry_after(%Req.Response{body: body} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [seconds | _] -> parse_seconds(seconds)
      [] -> throttle_seconds(body)
    end
  end

  defp parse_seconds(value) do
    case Integer.parse(value) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  defp throttle_seconds(%{"detail" => detail}) when is_binary(detail) do
    case Regex.run(~r/available in (\d+)/, detail) do
      [_match, seconds] -> String.to_integer(seconds)
      nil -> nil
    end
  end

  defp throttle_seconds(_body), do: nil

  defp present?(value), do: is_binary(value) and value != ""

  defp config, do: Application.fetch_env!(:ike_emails, __MODULE__)
end
