defmodule IkeEmails.Storage do
  @moduledoc """
  Where the invoice PDFs are kept. The adapter is configured with
  `config :ike_emails, IkeEmails.Storage, adapter: ...`: S3 everywhere, and an
  in-memory one in the tests.
  """

  @callback put(key :: String.t(), body :: binary(), content_type :: String.t()) ::
              :ok | {:error, term()}
  @callback fetch(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}
  @callback presigned_url(key :: String.t(), expires_in :: pos_integer()) :: String.t()

  @max_pdf_bytes 20_000_000

  @doc "The largest PDF that is kept, in bytes, for the invoices and the statements."
  def max_pdf_bytes, do: @max_pdf_bytes

  @doc "`:ok` for a PDF that can be kept, or `{:error, :too_large}` or `{:error, :not_a_pdf}`."
  def check_pdf(pdf) when byte_size(pdf) > @max_pdf_bytes, do: {:error, :too_large}
  def check_pdf("%PDF-" <> _rest), do: :ok
  def check_pdf(_other), do: {:error, :not_a_pdf}

  def put(key, body, content_type), do: adapter().put(key, body, content_type)

  @doc """
  The bytes of the object, for when the server needs them (a zip) and a link to
  send the browser to is not enough.
  """
  def fetch(key), do: adapter().fetch(key)

  def delete(key), do: adapter().delete(key)

  @doc """
  A temporary URL the browser can download the object from.
  """
  def presigned_url(key, expires_in), do: adapter().presigned_url(key, expires_in)

  defp adapter do
    :ike_emails |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:adapter)
  end
end
