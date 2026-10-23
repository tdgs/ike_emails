defmodule IkeEmails.Storage.InMemory do
  @moduledoc """
  Keeps the objects in an ETS table, so the tests need no S3 server. Keys are
  content addressed, so tests that run concurrently must not store the same
  bytes.
  """

  @behaviour IkeEmails.Storage

  @table __MODULE__

  @doc false
  def start do
    :ets.new(@table, [:named_table, :public, :set])
  end

  @impl true
  def put(key, body, content_type) do
    :ets.insert(@table, {key, body, content_type})
    :ok
  end

  @impl true
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @impl true
  def presigned_url(key, expires_in) do
    "http://storage.test/#{key}?expires=#{expires_in}"
  end

  def exists?(key), do: :ets.member(@table, key)

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, body, content_type}] -> {body, content_type}
      [] -> nil
    end
  end
end
