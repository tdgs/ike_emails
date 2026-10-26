defmodule IkeEmails.InvoiceExtractorStub do
  @moduledoc """
  Reads the invoices in the tests, in place of a language model. What it
  answers is set with `stub/1`, and every request is sent to the test as
  `{:extract_request, pdf, prompt, fields, model}`.

  The answer is global, so the tests that use it must not be async.
  """

  @behaviour IkeEmails.InvoiceExtractor.Client

  @doc """
  Answers every request with `result`: `{:ok, found}`, where `found` is a map
  with the string keys of the fields of the invoice, or `{:error, reason}`.

  `result` may also be a function, called for every request in the process
  that makes it, to answer later. See `hold/1`.
  """
  def stub(result) do
    Application.put_env(:ike_emails, __MODULE__, result: result, test: self())
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:ike_emails, __MODULE__) end)
  end

  @doc """
  Answers with `result` only once the test sends `:continue` to the process
  that makes the request, which is sent to the test as `{:held, pid}`.
  """
  def hold(result) do
    test = self()

    stub(fn ->
      send(test, {:held, self()})

      receive do
        :continue -> result
      end
    end)
  end

  @doc """
  What a model answers for an invoice of GitHub, as `Client.generate/4` returns
  it, for `changes` on top.
  """
  def found(changes \\ %{}) do
    Map.merge(
      %{
        "amount" => "146.38",
        "currency" => "usd",
        "date" => "2026-10-01",
        "issuer_name" => "GitHub, Inc.",
        "issuer_vat" => "EU 372 041 333",
        "number" => "GH-1001",
        "receiver_name" => nil,
        "receiver_vat" => nil
      },
      changes
    )
  end

  @impl true
  def generate(pdf, prompt, fields, model) do
    config = Application.get_env(:ike_emails, __MODULE__, [])
    if test = config[:test], do: send(test, {:extract_request, pdf, prompt, fields, model})

    case Keyword.get(config, :result, {:error, {:failed, "no answer was stubbed"}}) do
      result when is_function(result, 0) -> result.()
      result -> result
    end
  end
end
