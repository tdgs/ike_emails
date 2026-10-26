defmodule IkeEmails.InvoiceExtractor.Client do
  @moduledoc """
  What reads a PDF with a language model. The client is configured with
  `config :ike_emails, IkeEmails.InvoiceExtractor, client: ...`: ReqLLM
  everywhere, and a stub in the tests.
  """

  @doc """
  Asks `model` for the `fields` of the PDF.

  `fields` are `{name, description}` pairs, all of them text and each one
  `nil` when the PDF does not say. `model` is the `AI_MODEL` setting, such as
  `"anthropic:claude-sonnet-5-5"`.

  Returns the fields as a map with string keys, or `{:error, reason}` where
  `reason` is one of `:missing_key`, `:unauthorized`, `:rate_limited`,
  `:timeout`, `:invalid_response` or `{:failed, message}`.
  """
  @callback generate(
              pdf :: binary(),
              prompt :: String.t(),
              fields :: [{atom(), String.t()}],
              model :: String.t()
            ) :: {:ok, %{optional(String.t()) => term()}} | {:error, term()}
end
