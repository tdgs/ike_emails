defmodule IkeEmailsWeb.InvoiceUpload do
  @moduledoc """
  The PDF upload of the pages that add invoices.
  """

  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entries: 3]

  alias IkeEmails.Invoicing

  @doc """
  Sets up the single `:pdf` upload of a LiveView.
  """
  def allow(socket) do
    allow_upload(socket, :pdf,
      accept: ~w(.pdf),
      max_entries: 1,
      max_file_size: Invoicing.max_pdf_bytes()
    )
  end

  @doc """
  What is wrong with the upload, if anything, without touching it.
  """
  def problem(socket) do
    upload = socket.assigns.uploads.pdf

    cond do
      upload.entries == [] ->
        "Choose the PDF of the invoice."

      upload.errors != [] or Enum.any?(upload.entries, &(not &1.valid?)) ->
        "Fix the problem with the file first."

      Enum.any?(upload.entries, &(not &1.done?)) ->
        "Wait for the upload to finish."

      true ->
        nil
    end
  end

  @doc """
  Reads the uploaded PDF. It is called once the form is valid, so a mistake in
  the form does not lose the file.
  """
  def read_pdf(socket) do
    case problem(socket) do
      nil ->
        [{pdf, name}] =
          consume_uploaded_entries(socket, :pdf, fn %{path: path}, entry ->
            {:ok, {File.read!(path), entry.client_name}}
          end)

        {:ok, {pdf, name}}

      message ->
        {:error, message}
    end
  end

  @doc """
  What to tell about an error of `IkeEmails.Invoicing.create_invoice/4` that is
  not about the form.
  """
  def error_message(:not_a_pdf), do: "That file is not a PDF."
  def error_message(:too_large), do: "The PDF is larger than 20 MB."
  def error_message(:unknown_transaction), do: "The transaction no longer exists."

  def error_message({:storage, _reason}),
    do: "The PDF could not be stored. Choose the file again and retry."
end
