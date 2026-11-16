defmodule IkeEmailsWeb.InvoiceUpload do
  @moduledoc """
  The form of a new invoice with its PDF, on the pages that add invoices: the
  reconciliation and the invoices. Each page hands its events over to the functions
  here, with the invoice the form starts from (`base`), and they return the socket.

  The page assigns `:form`, `:pdf_error`, `:extract_error`, `:extracting?` and
  `:duplicate`, and the `:pdf` upload of `allow/1`. Reading the PDF with AI takes a
  few seconds, so it runs in an async task, `:extract`, which another panel or a
  cancelled upload cancels (see `reset_extract/1`).
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [
      allow_upload: 3,
      cancel_async: 2,
      cancel_upload: 3,
      consume_uploaded_entries: 3,
      push_patch: 2,
      put_flash: 3,
      start_async: 3
    ]

  require Logger

  alias IkeEmails.InvoiceExtractor
  alias IkeEmails.Invoicing
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmails.Settings
  alias IkeEmails.Storage

  @doc """
  Sets up the single `:pdf` upload of a LiveView.

  The file is uploaded as soon as it is chosen, not when the form is submitted,
  as reading it with AI happens before the submit.
  """
  def allow(socket) do
    allow_upload(socket, :pdf,
      accept: ~w(.pdf),
      max_entries: 1,
      max_file_size: Storage.max_pdf_bytes(),
      auto_upload: true
    )
  end

  @doc """
  Forgets a PDF that is still being read: the result would be for another panel or
  page, or for a file that is gone.
  """
  def reset_extract(socket) do
    socket
    |> cancel_async(:extract)
    |> assign(:extracting?, false)
    |> assign(:extract_error, nil)
  end

  def assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :invoice))
  end

  @doc "The event `validate` of the form."
  def validate(socket, %Invoice{} = base, params) do
    changeset = base |> Invoicing.change_invoice(params) |> Map.put(:action, :validate)

    socket
    |> assign(:pdf_error, nil)
    |> assign(:extract_error, nil)
    |> assign_form(changeset)
  end

  @doc "The event `cancel-upload` of the form."
  def cancel(socket, ref), do: socket |> cancel_upload(:pdf, ref) |> reset_extract()

  @doc """
  The event `extract`: starts reading the PDF with AI, unless it is being read already.
  The page passes the result of the task `:extract` to `extract_result/3`.
  """
  def extract(%{assigns: %{extracting?: true}} = socket, _base), do: socket

  def extract(socket, %Invoice{} = base) do
    with {:configured, true} <- {:configured, InvoiceExtractor.configured?()},
         {:ok, pdf} <- peek_pdf(socket) do
      hints = hints(base)
      business = Settings.business(socket.assigns.current_scope)

      socket
      |> assign(:extract_error, nil)
      |> assign(:extracting?, true)
      |> start_async(:extract, fn ->
        InvoiceExtractor.extract(pdf, hints: hints, business: business)
      end)
    else
      {:configured, false} ->
        assign(socket, :extract_error, extraction_error_message(:not_configured))

      {:error, message} ->
        assign(socket, :pdf_error, message)
    end
  end

  @doc "What `handle_async(:extract, result, socket)` of the page does with the result."
  def extract_result(socket, _base, {:ok, {:ok, found}}) when found == %{},
    do: extract_failed(socket, :invalid_response)

  def extract_result(socket, %Invoice{} = base, {:ok, {:ok, found}}) do
    params = merge_extracted(socket.assigns.form.params, found)
    changeset = base |> Invoicing.change_invoice(params) |> Map.put(:action, :validate)

    socket
    |> assign(:extracting?, false)
    |> assign(:extract_error, nil)
    |> assign_form(changeset)
    |> put_flash(:info, "Filled in from the PDF. Check the values before saving.")
  end

  def extract_result(socket, _base, {:ok, {:error, reason}}), do: extract_failed(socket, reason)
  def extract_result(socket, _base, {:exit, {:shutdown, :cancel}}), do: socket

  def extract_result(socket, _base, {:exit, reason}) do
    Logger.error("Reading an invoice with AI crashed: #{inspect(reason)}")
    extract_failed(socket, :crashed)
  end

  defp extract_failed(socket, reason) do
    socket
    |> assign(:extracting?, false)
    |> assign(:extract_error, extraction_error_message(reason))
  end

  @doc """
  The event `save` of a new invoice: stores it with its PDF, with the `opts` of
  `IkeEmails.Invoicing.create_invoice/5`, and goes to `done_path`.
  """
  def create(socket, %Invoice{} = base, params, opts, done_path) do
    changeset = Invoicing.change_invoice(base, params)

    with {:valid, true} <- {:valid, changeset.valid?},
         {:ok, {pdf, name}} <- read_pdf(socket) do
      socket.assigns.current_scope
      |> Invoicing.create_invoice(params, pdf, name, opts)
      |> created(socket, done_path)
    else
      {:valid, false} ->
        socket
        |> assign_form(Map.put(changeset, :action, :validate))
        |> assign(:pdf_error, problem(socket))

      {:error, message} ->
        socket
        |> assign_form(Map.put(changeset, :action, :validate))
        |> assign(:pdf_error, message)
    end
  end

  defp created({:ok, _invoice}, socket, done_path) do
    socket |> put_flash(:info, "Invoice added.") |> push_patch(to: done_path)
  end

  defp created({:error, %Ecto.Changeset{} = changeset}, socket, _done_path),
    do: assign_form(socket, changeset)

  defp created({:error, {:duplicate, invoice}}, socket, _done_path),
    do: assign(socket, :duplicate, invoice)

  defp created({:error, reason}, socket, _done_path) do
    if match?({:storage, _}, reason),
      do: Logger.error("Storing an invoice PDF failed: #{inspect(reason)}")

    assign(socket, :pdf_error, error_message(reason))
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
  Reads the uploaded PDF without consuming it, so that it can still be saved
  with the invoice afterwards.
  """
  def peek_pdf(socket) do
    case problem(socket) do
      nil ->
        [pdf] =
          consume_uploaded_entries(socket, :pdf, fn %{path: path}, _entry ->
            {:postpone, File.read!(path)}
          end)

        {:ok, pdf}

      message ->
        {:error, message}
    end
  end

  @doc """
  What is known of the invoice before the PDF is read, to help to read it: the
  amount, currency and date the form was started with.
  """
  def hints(%Invoice{} = invoice) do
    %{amount_input: invoice.amount_input, currency: invoice.currency, date: invoice.date}
  end

  @doc """
  The params of the form with what was found in the PDF on top of them.
  """
  def merge_extracted(params, found), do: Map.merge(params || %{}, found)

  @doc """
  What to tell about a reason why `IkeEmails.InvoiceExtractor.extract/2` could
  not read the PDF.
  """
  def extraction_error_message(:not_configured), do: "Reading invoices with AI is not set up."
  def extraction_error_message(:missing_key), do: "The API key of the AI provider is not set."
  def extraction_error_message(:unauthorized), do: "The AI provider did not accept the API key."
  def extraction_error_message(:rate_limited), do: "The AI provider is busy. Try again soon."
  def extraction_error_message(:timeout), do: "The AI provider took too long. Try again."

  def extraction_error_message(:invalid_response),
    do: "The AI could not read this invoice. Fill it in by hand."

  def extraction_error_message(_reason),
    do: "Reading the invoice failed. Fill it in by hand."

  @doc """
  What to tell about an error of `IkeEmails.Invoicing.create_invoice/5` that is
  not about the form.
  """
  def error_message(:not_a_pdf), do: "That file is not a PDF."

  def error_message(:too_large),
    do: "The PDF is larger than #{div(Storage.max_pdf_bytes(), 1_000_000)} MB."

  def error_message(:unknown_transaction), do: "The transaction no longer exists."

  def error_message({:storage, _reason}),
    do: "The PDF could not be stored. Choose the file again and retry."
end
