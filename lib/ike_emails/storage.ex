defmodule IkeEmails.Storage do
  @moduledoc """
  Where the invoice PDFs are kept. The adapter is configured with
  `config :ike_emails, IkeEmails.Storage, adapter: ...`: S3 everywhere, and an
  in-memory one in the tests.
  """

  @callback put(key :: String.t(), body :: binary(), content_type :: String.t()) ::
              :ok | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}
  @callback presigned_url(key :: String.t(), expires_in :: pos_integer()) :: String.t()

  def put(key, body, content_type), do: adapter().put(key, body, content_type)

  def delete(key), do: adapter().delete(key)

  @doc """
  A temporary URL the browser can download the object from.
  """
  def presigned_url(key, expires_in), do: adapter().presigned_url(key, expires_in)

  defp adapter do
    :ike_emails |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:adapter)
  end
end
