defmodule IkeEmailsWeb.InvoiceComponents do
  @moduledoc """
  Pieces shared by the reconciliation and invoice pages.
  """

  use IkeEmailsWeb, :html

  alias IkeEmails.Money

  @doc """
  Where a transaction stands in the reconciliation, see `IkeEmails.Banking.status/1`.
  """
  attr :status, :atom, values: [:invoiced, :exempt, :missing, :income], required: true
  attr :rest, :global

  def status_badge(assigns) do
    {label, icon, classes} =
      case assigns.status do
        :invoiced ->
          {"Invoiced", "hero-check-circle-mini",
           "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300 ring-emerald-500/30"}

        :exempt ->
          {"No invoice needed", "hero-minus-circle-mini",
           "bg-slate-500/10 text-slate-600 dark:text-slate-300 ring-slate-500/30"}

        :missing ->
          {"Missing invoice", "hero-exclamation-triangle-mini",
           "bg-amber-500/10 text-amber-700 dark:text-amber-300 ring-amber-500/40"}

        :income ->
          {"Income", "hero-arrow-down-left-mini",
           "bg-sky-500/10 text-sky-700 dark:text-sky-300 ring-sky-500/30"}
      end

    assigns = assign(assigns, label: label, icon: icon, classes: classes)

    ~H"""
    <span
      data-status={@status}
      class={[
        "inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset",
        @classes
      ]}
      {@rest}
    >
      <.icon name={@icon} class="size-3.5" />
      {@label}
    </span>
    """
  end

  @doc """
  The amount of an invoice, `1.234,56 €`.
  """
  attr :invoice, :map, required: true

  def invoice_amount(assigns) do
    ~H"""
    <span class="tabular-nums">{Money.format(@invoice.amount_cents, @invoice.currency)}</span>
    """
  end

  @doc """
  A panel over the page, closed with the X or the escape key by going to `close_path`.
  """
  attr :id, :string, required: true
  attr :close_path, :string, required: true
  attr :class, :string, default: "max-w-xl"
  slot :title, required: true
  slot :subtitle
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-30 flex items-start justify-center overflow-y-auto bg-black/40 p-4 backdrop-blur-[2px] sm:p-8"
      phx-window-keydown={JS.patch(@close_path)}
      phx-key="escape"
    >
      <div class={["w-full rounded-2xl bg-base-100 shadow-2xl ring-1 ring-base-300", @class]}>
        <div class="flex items-start justify-between gap-4 border-b border-base-300 px-6 py-4">
          <div class="min-w-0">
            <h2 class="text-lg font-semibold">{render_slot(@title)}</h2>
            <div :if={@subtitle != []} class="mt-0.5 text-sm text-base-content/70">
              {render_slot(@subtitle)}
            </div>
          </div>
          <.link
            patch={@close_path}
            id={"#{@id}-close"}
            aria-label="Close"
            class="rounded-md p-1 text-base-content/50 transition-colors hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>
        <div class="p-6">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  @doc """
  The form of an invoice. With an `:upload` it also takes the PDF, without one
  it only edits what is typed in. The page handles `validate`, `save` and
  `cancel-upload`.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, default: "invoice-form"
  attr :upload, :any, default: nil, doc: "the `:pdf` upload config of the page"
  attr :pdf_error, :string, default: nil
  attr :submit_label, :string, required: true
  slot :actions

  def invoice_form(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-change="validate" phx-submit="save" class="space-y-4">
      <div
        :if={@upload}
        id={"#{@id}-dropzone"}
        phx-drop-target={@upload.ref}
        class="rounded-xl border-2 border-dashed border-base-300 p-4 transition-colors hover:border-primary/50 phx-drop-target-active:border-primary phx-drop-target-active:bg-primary/5"
      >
        <div class="flex items-center gap-3">
          <label
            for={@upload.ref}
            class="inline-flex cursor-pointer items-center gap-2 rounded-lg bg-base-200 px-3 py-2 text-sm font-medium transition-colors hover:bg-base-300"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Choose PDF
          </label>
          <span class="text-sm text-base-content/60">or drop the invoice here</span>
        </div>
        <.live_file_input upload={@upload} class="sr-only" />

        <div
          :for={entry <- @upload.entries}
          id={"upload-#{entry.ref}"}
          class="mt-3 flex items-center gap-3 rounded-lg bg-base-200/60 px-3 py-2 text-sm"
        >
          <.icon name="hero-document-text" class="size-5 shrink-0 text-primary" />
          <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
          <progress class="progress progress-primary w-24" value={entry.progress} max="100">
            {entry.progress}%
          </progress>
          <button
            type="button"
            phx-click="cancel-upload"
            phx-value-ref={entry.ref}
            aria-label="Remove file"
            class="text-base-content/50 transition-colors hover:text-error"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <p
          :for={error <- upload_errors(@upload)}
          class="mt-2 flex items-center gap-1 text-sm text-error"
        >
          <.icon name="hero-exclamation-circle" class="size-4" />{upload_error_message(error)}
        </p>
        <div :for={entry <- @upload.entries} id={"upload-errors-#{entry.ref}"}>
          <p
            :for={error <- upload_errors(@upload, entry)}
            class="mt-2 flex items-center gap-1 text-sm text-error"
          >
            <.icon name="hero-exclamation-circle" class="size-4" />{upload_error_message(error)}
          </p>
        </div>
        <p
          :if={@pdf_error}
          id={"#{@id}-pdf-error"}
          class="mt-2 flex items-center gap-1 text-sm text-error"
        >
          <.icon name="hero-exclamation-circle" class="size-4" />{@pdf_error}
        </p>
      </div>

      <div class="grid grid-cols-3 gap-3">
        <div class="col-span-2">
          <.input
            field={@form[:amount_input]}
            type="text"
            label="Amount"
            inputmode="decimal"
            placeholder="12,50"
          />
        </div>
        <.input field={@form[:currency]} type="text" label="Currency" maxlength="3" />
      </div>
      <.input field={@form[:date]} type="date" label="Invoice date" />
      <.input field={@form[:issuer_name]} type="text" label="Issuer" />
      <div class="grid grid-cols-2 gap-3">
        <.input field={@form[:issuer_vat]} type="text" label="Issuer VAT" />
        <.input field={@form[:number]} type="text" label="Invoice number" />
      </div>
      <.input field={@form[:notes]} type="textarea" label="Notes" rows="2" />

      <div class="flex items-center justify-end gap-2 pt-2">
        {render_slot(@actions)}
        <.button type="submit" variant="primary" phx-disable-with="Saving...">
          {@submit_label}
        </.button>
      </div>
    </.form>
    """
  end

  defp upload_error_message(:too_large), do: "The file is larger than 20 MB."
  defp upload_error_message(:not_accepted), do: "Only PDF files are accepted."
  defp upload_error_message(:too_many_files), do: "Only one file can be uploaded."
  defp upload_error_message(_error), do: "The file could not be uploaded."
end
