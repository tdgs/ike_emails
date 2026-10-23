defmodule IkeEmails.Storage.S3 do
  @moduledoc """
  Stores objects in an S3 bucket, or any S3-compatible server when
  `:endpoint_url` is set (SeaweedFS in development, see `compose.yaml`).
  """

  @behaviour IkeEmails.Storage

  @impl true
  def put(key, body, content_type) do
    client()
    |> Req.put(url: object_url(key), body: body, headers: [{"content-type", content_type}])
    |> to_result(&(&1 in 200..299))
  end

  @impl true
  def delete(key) do
    client()
    |> Req.delete(url: object_url(key))
    |> to_result(&(&1 in 200..299 or &1 == 404))
  end

  @impl true
  def presigned_url(key, expires_in) do
    config = config()

    ReqS3.presign_url(
      bucket: config[:bucket],
      key: key,
      endpoint_url: config[:endpoint_url],
      access_key_id: config[:access_key_id],
      secret_access_key: config[:secret_access_key],
      region: config[:region],
      expires: expires_in
    )
  end

  @doc """
  Creates the bucket unless it exists. Used by `mix storage.setup`.
  """
  def ensure_bucket do
    case Req.put(client(), url: "s3://#{config()[:bucket]}") do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 409, body: body}} when is_binary(body) ->
        if body =~ "BucketAlready", do: :ok, else: {:error, {:unexpected_status, 409, body}}

      other ->
        to_result(other, fn _ -> false end)
    end
  end

  defp client do
    config = config()

    Req.new(retry: :transient, max_retries: 2)
    |> ReqS3.attach(
      aws_sigv4: [
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region]
      ],
      aws_endpoint_url_s3: config[:endpoint_url]
    )
  end

  defp object_url(key), do: "s3://#{config()[:bucket]}/#{key}"

  defp config, do: Application.fetch_env!(:ike_emails, __MODULE__)

  defp to_result({:ok, %{status: status} = response}, ok?) do
    if ok?.(status), do: :ok, else: {:error, {:unexpected_status, status, response.body}}
  end

  defp to_result({:error, exception}, _ok?), do: {:error, exception}
end
