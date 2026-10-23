defmodule Mix.Tasks.Storage.Setup do
  @shortdoc "Creates the S3 bucket of the invoice PDFs"

  @moduledoc """
  Creates the bucket the invoice PDFs are stored in, unless it exists.

  In development it needs the local S3 server of `compose.yaml`:

      docker compose up -d
      mix storage.setup
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:req)

    case IkeEmails.Storage.S3.ensure_bucket() do
      :ok -> Mix.shell().info("The invoice bucket is ready.")
      {:error, reason} -> Mix.raise("Could not create the invoice bucket: #{inspect(reason)}")
    end
  end
end
