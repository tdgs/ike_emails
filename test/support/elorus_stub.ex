defmodule IkeEmails.ElorusStub do
  @moduledoc """
  Answers the requests to the Elorus API in the tests, through `Req.Test`.
  Every request is sent to the test as `{:elorus_request, conn}`.
  """

  @doc """
  An invoice as the API returns it. The values are the examples of the API
  documentation.
  """
  def invoice_json(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "1050000300010040",
        "status" => "issued",
        "draft" => false,
        "representation" => "Invoice #A-1",
        "number" => "1",
        "sequence_flat" => "A-",
        "date" => "2026-10-25",
        "due_date" => "2026-11-25",
        "client" => "3300000040000100",
        "client_display_name" => "Acme Inc.",
        "client_vat_number" => "123451234",
        "currency_code" => "EUR",
        "net" => "80.00",
        "total" => "100.00",
        "payable" => "100.00",
        "paid" => "0.00",
        "permalink" => "//app.elorus.com/p/abc/"
      },
      attrs
    )
  end

  @doc """
  A PDF that differs for every `seed`.
  """
  def pdf(seed \\ "") do
    "%PDF-1.4\n% elorus invoice #{seed}\n%%EOF\n"
  end

  @doc """
  Answers the list of invoices with `:invoices` (as `invoice_json/1` maps), and
  the PDF of the invoice `id` with `pdfs[id]` (a PDF of its own by default).

  With `:status` every request is answered with that status and no content, to
  test the errors. With `:pdf_status` only the downloads of the PDFs are.
  """
  def stub(opts \\ []) do
    test = self()
    invoices = Keyword.get(opts, :invoices, [])
    pdfs = Keyword.get(opts, :pdfs, %{})
    status = Keyword.get(opts, :status, 200)
    pdf_status = Keyword.get(opts, :pdf_status, 200)

    Req.Test.stub(IkeEmails.Elorus, fn conn ->
      send(test, {:elorus_request, conn})

      case {status, String.split(conn.request_path, "/", trim: true)} do
        {status, _path} when status != 200 ->
          Plug.Conn.send_resp(conn, status, "")

        {200, ["v1.2", "invoices"]} ->
          Req.Test.json(conn, %{
            "count" => length(invoices),
            "next" => nil,
            "previous" => nil,
            "results" => invoices
          })

        {200, ["v1.2", "invoices", _id, "pdf"]} when pdf_status != 200 ->
          Plug.Conn.send_resp(conn, pdf_status, "")

        {200, ["v1.2", "invoices", id, "pdf"]} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/pdf")
          |> Plug.Conn.send_resp(200, Map.get_lazy(pdfs, id, fn -> pdf(id) end))
      end
    end)
  end

  @doc """
  The query parameters of the request received last.
  """
  def last_query do
    case request_conns() do
      [] -> nil
      conns -> conns |> List.last() |> Plug.Conn.fetch_query_params() |> Map.fetch!(:query_params)
    end
  end

  defp request_conns(acc \\ []) do
    receive do
      {:elorus_request, conn} -> request_conns([conn | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  The paths of the requests received so far.
  """
  def request_paths, do: Enum.map(request_conns(), & &1.request_path)

  @doc """
  The headers of each of the requests received so far, as maps from the name
  (in lowercase) to the value: `"authorization"` and `"x-elorus-organization"`
  say whose credentials a request carried.
  """
  def request_headers, do: Enum.map(request_conns(), &Map.new(&1.req_headers))

  @doc """
  The headers of the request received last, or `nil` without one.
  """
  def last_headers, do: List.last(request_headers())
end
