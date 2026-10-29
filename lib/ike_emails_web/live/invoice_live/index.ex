defmodule IkeEmailsWeb.InvoiceLive.Index do
  @moduledoc """
  All the invoices (expenses), matched to bank transactions or not yet.
  """

  use IkeEmailsWeb, :live_view

  require Logger

  import IkeEmailsWeb.InvoiceComponents

  alias IkeEmails.InvoiceExtractor
  alias IkeEmails.Invoicing
  alias IkeEmails.Invoicing.Invoice
  alias IkeEmailsWeb.InvoiceUpload

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Invoices")
     |> assign(:search, "")
     |> assign(:invoice, nil)
     |> assign(:duplicate, nil)
     |> assign(:pdf_error, nil)
     |> assign(:extract_configured?, InvoiceExtractor.configured?())
     |> assign(:extracting?, false)
     |> assign(:extract_error, nil)
     |> stream(:invoices, [])
     |> InvoiceUpload.allow()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> apply_action(socket.assigns.live_action, params) |> load_invoices()}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:invoice, nil) |> reset_extract()
  end

  defp apply_action(socket, :new, _params) do
    invoice = %Invoice{}

    socket
    |> assign(:invoice, invoice)
    |> assign(:duplicate, nil)
    |> assign(:pdf_error, nil)
    |> reset_extract()
    |> assign_form(Invoicing.change_invoice(invoice))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    invoice = Invoicing.get_invoice!(socket.assigns.current_scope, id)

    socket
    |> assign(:invoice, invoice)
    |> reset_extract()
    |> assign_form(Invoicing.change_invoice(invoice))
  end

  defp load_invoices(socket) do
    invoices =
      Invoicing.list_invoices(socket.assigns.current_scope, search: socket.assigns.search)

    stream(socket, :invoices, invoices, reset: true)
  end

  # A PDF that is still being read is forgotten: the result would be for another
  # page, or for a file that is gone
  defp reset_extract(socket) do
    socket
    |> cancel_async(:extract)
    |> assign(:extracting?, false)
    |> assign(:extract_error, nil)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :invoice))
  end

  ## Events

  @impl true
  def handle_event("search", %{"q" => term}, socket) do
    {:noreply, socket |> assign(:search, term) |> load_invoices()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    {:ok, invoice} =
      scope |> Invoicing.get_invoice!(id) |> then(&Invoicing.delete_invoice(scope, &1))

    {:noreply, stream_delete(socket, :invoices, invoice)}
  end

  def handle_event("validate", %{"invoice" => params}, socket) do
    changeset =
      socket.assigns.invoice |> Invoicing.change_invoice(params) |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:pdf_error, nil)
     |> assign(:extract_error, nil)
     |> assign_form(changeset)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, socket |> cancel_upload(:pdf, ref) |> reset_extract()}
  end

  def handle_event("extract", _params, %{assigns: %{extracting?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("extract", _params, socket) do
    with {:configured, true} <- {:configured, InvoiceExtractor.configured?()},
         {:ok, pdf} <- InvoiceUpload.peek_pdf(socket) do
      hints = InvoiceUpload.hints(socket.assigns.invoice)

      {:noreply,
       socket
       |> assign(:extract_error, nil)
       |> assign(:extracting?, true)
       |> start_async(:extract, fn -> InvoiceExtractor.extract(pdf, hints: hints) end)}
    else
      {:configured, false} ->
        message = InvoiceUpload.extraction_error_message(:not_configured)
        {:noreply, assign(socket, :extract_error, message)}

      {:error, message} ->
        {:noreply, assign(socket, :pdf_error, message)}
    end
  end

  def handle_event("save", %{"invoice" => params}, %{assigns: %{live_action: :edit}} = socket) do
    case Invoicing.update_invoice(socket.assigns.current_scope, socket.assigns.invoice, params) do
      {:ok, _invoice} ->
        {:noreply,
         socket |> put_flash(:info, "Invoice updated.") |> push_patch(to: ~p"/invoices")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  def handle_event("save", %{"invoice" => params}, %{assigns: %{live_action: :new}} = socket) do
    changeset = Invoicing.change_invoice(socket.assigns.invoice, params)

    with {:valid, true} <- {:valid, changeset.valid?},
         {:ok, {pdf, name}} <- InvoiceUpload.read_pdf(socket) do
      socket.assigns.current_scope
      |> Invoicing.create_invoice(params, pdf, name)
      |> handle_created(socket)
    else
      {:valid, false} ->
        {:noreply,
         socket
         |> assign_form(Map.put(changeset, :action, :validate))
         |> assign(:pdf_error, InvoiceUpload.problem(socket))}

      {:error, message} ->
        {:noreply,
         socket
         |> assign_form(Map.put(changeset, :action, :validate))
         |> assign(:pdf_error, message)}
    end
  end

  ## Reading the PDF with AI

  @impl true
  def handle_async(:extract, {:ok, {:ok, found}}, socket) when found == %{} do
    {:noreply, extract_failed(socket, :invalid_response)}
  end

  def handle_async(:extract, {:ok, {:ok, found}}, socket) do
    %{invoice: invoice, form: form} = socket.assigns
    params = InvoiceUpload.merge_extracted(form.params, found)
    changeset = invoice |> Invoicing.change_invoice(params) |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:extracting?, false)
     |> assign(:extract_error, nil)
     |> assign_form(changeset)
     |> put_flash(:info, "Filled in from the PDF. Check the values before saving.")}
  end

  def handle_async(:extract, {:ok, {:error, reason}}, socket) do
    {:noreply, extract_failed(socket, reason)}
  end

  def handle_async(:extract, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:extract, {:exit, reason}, socket) do
    Logger.error("Reading an invoice with AI crashed: #{inspect(reason)}")
    {:noreply, extract_failed(socket, :crashed)}
  end

  defp extract_failed(socket, reason) do
    socket
    |> assign(:extracting?, false)
    |> assign(:extract_error, InvoiceUpload.extraction_error_message(reason))
  end

  defp handle_created({:ok, _invoice}, socket) do
    {:noreply, socket |> put_flash(:info, "Invoice added.") |> push_patch(to: ~p"/invoices")}
  end

  defp handle_created({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply, assign_form(socket, changeset)}
  end

  defp handle_created({:error, {:duplicate, invoice}}, socket) do
    {:noreply, assign(socket, :duplicate, invoice)}
  end

  defp handle_created({:error, reason}, socket) do
    if match?({:storage, _}, reason),
      do: Logger.error("Storing an invoice PDF failed: #{inspect(reason)}")

    {:noreply, assign(socket, :pdf_error, InvoiceUpload.error_message(reason))}
  end

  ## Rendering

  defp format_date(date), do: Calendar.strftime(date, "%d/%m/%Y")
  defp month_param(date), do: Calendar.strftime(date, "%Y-%m")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:invoices}>
      <.header>
        Invoices
        <:subtitle>Every expense with its PDF, and the payments it is matched to.</:subtitle>
        <:actions>
          <.button patch={~p"/invoices/new"} id="new-invoice" variant="primary">
            <.icon name="hero-plus" class="size-4" /> New invoice
          </.button>
        </:actions>
      </.header>

      <.form for={to_form(%{"q" => @search}, as: :search)} id="invoice-search" phx-change="search">
        <.input
          name="q"
          value={@search}
          type="search"
          placeholder="Search by issuer, receiver or invoice number"
          phx-debounce="250"
        />
      </.form>

      <div
        id="invoices"
        phx-update="stream"
        class="divide-y divide-base-300 overflow-hidden rounded-2xl bg-base-100 ring-1 ring-base-300"
      >
        <div id="invoices-empty" class="hidden px-6 py-12 text-center text-base-content/60 only:block">
          No invoices yet.
        </div>
        <div :for={{id, invoice} <- @streams.invoices} id={id} class="px-4 py-4 sm:px-6">
          <div class="flex flex-wrap items-start gap-x-4 gap-y-2">
            <div class="w-24 shrink-0 pt-0.5 text-sm tabular-nums text-base-content/60">
              {format_date(invoice.date)}
            </div>
            <div class="min-w-0 flex-1 basis-56">
              <div class="font-medium">
                {invoice.issuer_name}
                <span :if={invoice.receiver_name} class="font-normal text-base-content/60">
                  → {invoice.receiver_name}
                </span>
              </div>
              <div class="truncate text-sm text-base-content/60">
                {Enum.join(
                  Enum.reject(
                    [
                      invoice.issuer_vat && "VAT #{invoice.issuer_vat}",
                      invoice.number && "#" <> invoice.number
                    ],
                    &is_nil/1
                  ),
                  " · "
                )}
              </div>
            </div>
            <div class="font-semibold"><.invoice_amount invoice={invoice} /></div>
            <div class="flex items-center gap-1">
              <a
                href={~p"/invoices/#{invoice.id}/pdf"}
                target="_blank"
                rel="noopener"
                id={"pdf-#{invoice.id}"}
                class="rounded-lg px-2.5 py-1 text-sm font-medium text-primary transition-colors hover:bg-primary/10"
              >
                PDF
              </a>
              <.link
                patch={~p"/invoices/#{invoice.id}/edit"}
                id={"edit-invoice-#{invoice.id}"}
                class="rounded-lg px-2.5 py-1 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-200"
              >
                Edit
              </.link>
              <button
                type="button"
                id={"delete-invoice-#{invoice.id}"}
                phx-click="delete"
                phx-value-id={invoice.id}
                data-confirm="Delete this invoice and its PDF?"
                class="rounded-lg px-2.5 py-1 text-sm font-medium text-base-content/70 transition-colors hover:bg-error/10 hover:text-error"
              >
                Delete
              </button>
            </div>
          </div>

          <div class="mt-3 flex flex-wrap items-center gap-2 sm:pl-28">
            <span
              :if={invoice.transactions == []}
              id={"unmatched-#{invoice.id}"}
              class="inline-flex items-center gap-1 whitespace-nowrap rounded-full bg-sky-500/10 px-2.5 py-0.5 text-xs font-medium text-sky-700 ring-1 ring-inset ring-sky-500/30 dark:text-sky-300"
            >
              <.icon name="hero-link-slash-mini" class="size-3.5" /> Unmatched
            </span>
            <.link
              :for={transaction <- invoice.transactions}
              navigate={~p"/?month=#{month_param(transaction.date)}"}
              id={"#{id}-transaction-#{transaction.id}"}
              class="inline-flex max-w-full items-center gap-1.5 truncate rounded-lg bg-base-200/60 px-2.5 py-1 text-sm transition-colors hover:bg-base-200"
            >
              <.icon
                name="hero-banknotes"
                class="size-4 shrink-0 text-emerald-600 dark:text-emerald-400"
              />
              {Calendar.strftime(transaction.date, "%d/%m")} · {transaction.description}
              <span class="tabular-nums text-base-content/60">
                {IkeEmails.Money.format(IkeEmails.Money.cents_from_decimal(transaction.amount))}
              </span>
            </.link>
          </div>
        </div>
      </div>

      <.panel :if={@live_action == :new} id="new-invoice-panel" close_path={~p"/invoices"}>
        <:title>New invoice</:title>
        <:subtitle>
          Upload it now, match it to a payment later from the reconciliation page.
        </:subtitle>
        <div
          :if={@duplicate}
          id="duplicate-notice"
          class="mb-4 rounded-xl bg-amber-500/10 p-4 text-sm ring-1 ring-amber-500/30"
        >
          This PDF is already stored as the invoice of <strong>{@duplicate.issuer_name}</strong>
          ({format_date(@duplicate.date)}, <.invoice_amount invoice={@duplicate} />).
        </div>
        <.invoice_form
          form={@form}
          upload={@uploads.pdf}
          pdf_error={@pdf_error}
          extract_configured?={@extract_configured?}
          extracting?={@extracting?}
          extract_error={@extract_error}
          submit_label="Save invoice"
        >
          <:actions>
            <.link patch={~p"/invoices"} class="btn btn-ghost">Cancel</.link>
          </:actions>
        </.invoice_form>
      </.panel>

      <.panel :if={@live_action == :edit} id="edit-invoice-panel" close_path={~p"/invoices"}>
        <:title>Edit invoice</:title>
        <:subtitle>{@invoice.file_name}</:subtitle>
        <.invoice_form form={@form} submit_label="Save changes">
          <:actions>
            <.link patch={~p"/invoices"} class="btn btn-ghost">Cancel</.link>
          </:actions>
        </.invoice_form>
      </.panel>
    </Layouts.app>
    """
  end
end
