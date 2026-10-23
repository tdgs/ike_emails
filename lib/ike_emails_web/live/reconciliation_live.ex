defmodule IkeEmailsWeb.ReconciliationLive do
  @moduledoc """
  The monthly routine: the transactions of a month, each with the invoices that
  pay for it, and what is still missing.
  """

  use IkeEmailsWeb, :live_view

  require Logger

  import IkeEmailsWeb.InvoiceComponents

  alias IkeEmails.Banking
  alias IkeEmails.Invoicing
  alias IkeEmails.Money
  alias IkeEmailsWeb.InvoiceUpload

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reconciliation")
     |> assign(:transaction, nil)
     |> assign(:months, [])
     |> assign(:summary, nil)
     |> assign(:duplicate, nil)
     |> assign(:pdf_error, nil)
     |> assign(:suggestion_search, "")
     |> stream(:transactions, [])
     |> stream(:suggestions, [])
     |> InvoiceUpload.allow()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = open_transaction(socket, socket.assigns.live_action, params)
    month = month_from(params["month"], socket.assigns.transaction)

    {:noreply, load_month(socket, month)}
  end

  defp open_transaction(socket, :attach, %{"id" => id}) do
    transaction = Banking.get_transaction!(id)
    prefill = Invoicing.new_invoice_for(transaction)

    socket
    |> assign(:transaction, transaction)
    |> assign(:prefill, prefill)
    |> assign(:duplicate, nil)
    |> assign(:pdf_error, nil)
    |> assign(:suggestion_search, "")
    |> assign_form(Invoicing.change_invoice(prefill))
    |> load_suggestions()
  end

  defp open_transaction(socket, _action, _params) do
    assign(socket, :transaction, nil)
  end

  defp month_from(param, transaction) do
    with param when is_binary(param) <- param,
         {:ok, date} <- Date.from_iso8601(param <> "-01") do
      date
    else
      _ -> default_month(transaction)
    end
  end

  defp default_month(%{date: date}), do: Date.beginning_of_month(date)

  defp default_month(nil) do
    case Banking.months_with_transactions() do
      [latest | _] -> latest
      [] -> Date.beginning_of_month(Date.utc_today())
    end
  end

  defp load_month(socket, month) do
    transactions = Banking.list_transactions_for_month(month.year, month.month)

    socket
    |> assign(:month, month)
    |> assign(:months, Banking.months_with_transactions())
    |> assign(:summary, Banking.month_summary(transactions))
    |> stream(:transactions, transactions, reset: true)
  end

  defp refresh(socket), do: load_month(socket, socket.assigns.month)

  defp load_suggestions(socket) do
    suggestions =
      Invoicing.suggest_invoices(socket.assigns.transaction, socket.assigns.suggestion_search)

    stream(socket, :suggestions, suggestions, reset: true)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :invoice))
  end

  ## Events

  @impl true
  def handle_event("jump", %{"month" => month}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?month=#{month}")}
  end

  def handle_event("mark_no_invoice", %{"exempt" => %{"id" => id, "note" => note}}, socket) do
    transaction = Banking.get_transaction!(id)

    case Banking.mark_no_invoice(transaction, note) do
      {:ok, _transaction} ->
        {:noreply, refresh(socket)}

      {:error, :has_invoices} ->
        {:noreply, socket |> put_flash(:error, "That transaction has invoices.") |> refresh()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "The reason is too long.")}
    end
  end

  def handle_event("clear_no_invoice", %{"id" => id}, socket) do
    {:ok, _transaction} = id |> Banking.get_transaction!() |> Banking.clear_no_invoice()
    {:noreply, refresh(socket)}
  end

  def handle_event(
        "detach",
        %{"invoice-id" => invoice_id, "transaction-id" => transaction_id},
        socket
      ) do
    :ok =
      Invoicing.detach(
        Invoicing.get_invoice!(invoice_id),
        Banking.get_transaction!(transaction_id)
      )

    {:noreply, refresh(socket)}
  end

  def handle_event("validate", %{"invoice" => params}, socket) do
    changeset =
      socket.assigns.prefill |> Invoicing.change_invoice(params) |> Map.put(:action, :validate)

    {:noreply, socket |> assign(:pdf_error, nil) |> assign_form(changeset)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  def handle_event("save", %{"invoice" => params}, socket) do
    changeset = Invoicing.change_invoice(socket.assigns.prefill, params)

    with {:valid, true} <- {:valid, changeset.valid?},
         {:ok, {pdf, name}} <- InvoiceUpload.read_pdf(socket) do
      transaction_ids = [socket.assigns.transaction.id]

      params
      |> Invoicing.create_invoice(pdf, name, transaction_ids: transaction_ids)
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

  def handle_event("attach_existing", %{"id" => invoice_id}, socket) do
    invoice = Invoicing.get_invoice!(invoice_id)
    :ok = Invoicing.attach(invoice, socket.assigns.transaction)

    {:noreply,
     socket
     |> put_flash(:info, "Invoice attached.")
     |> push_patch(to: month_path(socket.assigns.month))}
  end

  def handle_event("search_suggestions", %{"q" => term}, socket) do
    {:noreply, socket |> assign(:suggestion_search, term) |> load_suggestions()}
  end

  defp handle_created({:ok, _invoice}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Invoice added.")
     |> push_patch(to: month_path(socket.assigns.month))}
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

  defp month_param(month), do: Calendar.strftime(month, "%Y-%m")
  defp month_path(month), do: ~p"/?month=#{month_param(month)}"
  defp month_title(month), do: Calendar.strftime(month, "%B %Y")
  defp format_date(date), do: Calendar.strftime(date, "%d/%m/%Y")

  defp transaction_money(transaction),
    do: transaction.amount |> Money.cents_from_decimal() |> Money.format()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:reconciliation}>
      <.header>
        Reconciliation
        <:subtitle>Match every payment of the month to its invoice.</:subtitle>
      </.header>

      <div id="month-nav" class="flex items-center justify-between gap-3">
        <.link
          patch={month_path(Date.shift(@month, month: -1))}
          id="prev-month"
          aria-label="Previous month"
          class="rounded-lg p-2 text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-chevron-left" class="size-5" />
        </.link>
        <div class="flex flex-col items-center">
          <h2 id="month-title" class="text-xl font-semibold tracking-tight">{month_title(@month)}</h2>
          <.form
            for={to_form(%{"month" => month_param(@month)}, as: :jump)}
            id="month-form"
            phx-change="jump"
            class="mt-1"
          >
            <select
              name="month"
              id="month-select"
              class="select select-ghost select-xs text-base-content/60"
              aria-label="Jump to month"
            >
              <option :if={@month not in @months} value={month_param(@month)} selected>
                {month_title(@month)}
              </option>
              <option
                :for={month <- @months}
                value={month_param(month)}
                selected={month == @month}
              >
                {month_title(month)}
              </option>
            </select>
          </.form>
        </div>
        <.link
          patch={month_path(Date.shift(@month, month: 1))}
          id="next-month"
          aria-label="Next month"
          class="rounded-lg p-2 text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-chevron-right" class="size-5" />
        </.link>
      </div>

      <.summary summary={@summary} />

      <div
        id="transactions"
        phx-update="stream"
        class="divide-y divide-base-300 overflow-hidden rounded-2xl bg-base-100 ring-1 ring-base-300"
      >
        <div
          id="transactions-empty"
          class="hidden px-6 py-12 text-center text-base-content/60 only:block"
        >
          No transactions in {month_title(@month)}.
        </div>
        <.transaction_row
          :for={{id, transaction} <- @streams.transactions}
          id={id}
          transaction={transaction}
          month={@month}
        />
      </div>

      <.panel
        :if={@transaction}
        id="attach-panel"
        close_path={month_path(@month)}
        class="max-w-4xl"
      >
        <:title>Add an invoice</:title>
        <:subtitle>
          <span id="attach-transaction">
            {format_date(@transaction.date)} · {@transaction.description} ·
            <span class="font-medium tabular-nums">{transaction_money(@transaction)}</span>
          </span>
        </:subtitle>

        <div
          :if={@duplicate}
          id="duplicate-notice"
          class="mb-6 flex items-center justify-between gap-4 rounded-xl bg-amber-500/10 p-4 text-sm ring-1 ring-amber-500/30"
        >
          <p>
            This PDF is already stored as the invoice of <strong>{@duplicate.issuer_name}</strong>
            ({format_date(@duplicate.date)}, <.invoice_amount invoice={@duplicate} />).
          </p>
          <.button id="attach-duplicate" phx-click="attach_existing" phx-value-id={@duplicate.id}>
            Attach it
          </.button>
        </div>

        <div class="grid gap-8 md:grid-cols-2">
          <section>
            <h3 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Upload a new invoice
            </h3>
            <.invoice_form
              form={@form}
              upload={@uploads.pdf}
              pdf_error={@pdf_error}
              submit_label="Save invoice"
            />
          </section>

          <section>
            <h3 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Or attach one you already have
            </h3>
            <.form
              for={to_form(%{"q" => @suggestion_search}, as: :suggestions)}
              id="suggestion-search"
              phx-change="search_suggestions"
            >
              <.input
                name="q"
                value={@suggestion_search}
                type="search"
                placeholder="Search by issuer or number"
                phx-debounce="250"
              />
            </.form>
            <div id="suggestions" phx-update="stream" class="space-y-2">
              <p id="suggestions-empty" class="hidden text-sm text-base-content/60 only:block">
                No invoices to attach.
              </p>
              <.suggestion
                :for={{id, invoice} <- @streams.suggestions}
                id={id}
                invoice={invoice}
                transaction={@transaction}
              />
            </div>
          </section>
        </div>
      </.panel>
    </Layouts.app>
    """
  end

  attr :summary, :map, required: true

  defp summary(assigns) do
    summary = assigns.summary
    reconciled = summary.invoiced + summary.exempt
    payments = reconciled + summary.missing
    assigns = assign(assigns, reconciled: reconciled, payments: payments)

    ~H"""
    <div id="month-summary" class="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <.stat id="stat-invoiced" label="Invoiced" value={@summary.invoiced} />
      <.stat id="stat-exempt" label="No invoice needed" value={@summary.exempt} />
      <.stat
        id="stat-missing"
        label="Missing"
        value={@summary.missing}
        tone={if(@summary.missing > 0, do: :warn)}
      >
        <span :if={@summary.missing > 0} class="tabular-nums">
          {Money.format(@summary.missing_cents)}
        </span>
      </.stat>
      <.stat id="stat-income" label="Income" value={@summary.income} />
      <div :if={@payments > 0} class="col-span-2 sm:col-span-4">
        <div class="mb-1 flex justify-between text-xs text-base-content/60">
          <span id="reconciled-count">{@reconciled} of {@payments} payments reconciled</span>
          <span :if={@summary.missing == 0} class="font-medium text-emerald-600 dark:text-emerald-400">
            All done
          </span>
        </div>
        <progress
          id="reconciled-progress"
          class="progress progress-success h-1.5 w-full"
          value={@reconciled}
          max={@payments}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: nil
  slot :inner_block

  defp stat(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-xl p-4 ring-1 ring-inset",
        if(@tone == :warn,
          do: "bg-amber-500/10 ring-amber-500/30",
          else: "bg-base-100 ring-base-300"
        )
      ]}
    >
      <div class="text-xs font-medium uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class="mt-1 flex items-baseline gap-2">
        <span class="text-2xl font-semibold tabular-nums">{@value}</span>
        <span class="text-sm text-base-content/70">{render_slot(@inner_block)}</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :transaction, :map, required: true
  attr :month, :any, required: true

  defp transaction_row(assigns) do
    transaction = assigns.transaction
    status = Banking.status(transaction)
    debit? = Decimal.negative?(transaction.amount)
    assigns = assign(assigns, status: status, debit?: debit?)

    ~H"""
    <div id={@id} data-status={@status} class="px-4 py-4 sm:px-6">
      <div class="flex flex-wrap items-start gap-x-4 gap-y-2">
        <div class="w-20 shrink-0 pt-0.5 text-sm tabular-nums text-base-content/60">
          {Calendar.strftime(@transaction.date, "%d/%m")}
        </div>
        <div class="min-w-0 flex-1 basis-56">
          <div class="font-medium">{@transaction.description}</div>
          <div
            :if={@transaction.sender_details || @transaction.additional_information}
            class="truncate text-sm text-base-content/60"
          >
            {Enum.join(
              Enum.reject(
                [@transaction.sender_details, @transaction.additional_information],
                &is_nil/1
              ),
              " · "
            )}
          </div>
        </div>
        <div class="text-right">
          <div class={[
            "font-semibold tabular-nums",
            !@debit? && "text-emerald-600 dark:text-emerald-400"
          ]}>
            {transaction_money(@transaction)}
          </div>
          <div :if={@transaction.conversion_details} class="text-xs tabular-nums text-base-content/60">
            {@transaction.conversion_details}
          </div>
        </div>
        <div class="w-40 text-right">
          <.status_badge status={@status} id={"status-#{@transaction.id}"} />
        </div>
      </div>

      <div class="mt-3 space-y-2 sm:pl-24">
        <div
          :for={invoice <- @transaction.invoices}
          id={"#{@id}-invoice-#{invoice.id}"}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg bg-base-200/60 px-3 py-2 text-sm"
        >
          <.icon name="hero-document-text" class="size-4 shrink-0 text-primary" />
          <span class="font-medium">{invoice.issuer_name}</span>
          <span :if={invoice.number} class="text-base-content/60">#{invoice.number}</span>
          <span class="text-base-content/60">{format_date(invoice.date)}</span>
          <.invoice_amount invoice={invoice} />
          <span class="flex-1" />
          <a
            href={~p"/invoices/#{invoice.id}/pdf"}
            target="_blank"
            rel="noopener"
            class="font-medium text-primary hover:underline"
          >
            PDF
          </a>
          <button
            type="button"
            id={"detach-#{@transaction.id}-#{invoice.id}"}
            phx-click="detach"
            phx-value-invoice-id={invoice.id}
            phx-value-transaction-id={@transaction.id}
            aria-label="Detach invoice"
            class="text-base-content/50 transition-colors hover:text-error"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div
          :if={@transaction.no_invoice}
          id={"#{@id}-note"}
          class="flex items-center gap-3 rounded-lg bg-base-200/60 px-3 py-2 text-sm"
        >
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-4 shrink-0 text-base-content/50" />
          <span class="min-w-0 flex-1 break-words">
            <span class="font-medium">No invoice needed</span>
            <span :if={@transaction.no_invoice_note} class="text-base-content/70">
              &middot; {@transaction.no_invoice_note}
            </span>
          </span>
          <button
            type="button"
            id={"clear-no-invoice-#{@transaction.id}"}
            phx-click="clear_no_invoice"
            phx-value-id={@transaction.id}
            class="font-medium text-primary hover:underline"
          >
            Clear
          </button>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.link
            patch={~p"/transactions/#{@transaction.id}/invoice?month=#{month_param(@month)}"}
            id={"add-invoice-#{@transaction.id}"}
            class="inline-flex items-center gap-1 rounded-lg px-2.5 py-1 text-sm font-medium text-primary transition-colors hover:bg-primary/10"
          >
            <.icon name="hero-plus-small" class="size-4" /> Add invoice
          </.link>
          <button
            :if={@status in [:missing, :income]}
            type="button"
            id={"toggle-no-invoice-#{@transaction.id}"}
            phx-click={JS.toggle(to: "#no-invoice-form-#{@transaction.id}", display: "flex")}
            class="inline-flex items-center gap-1 rounded-lg px-2.5 py-1 text-sm font-medium text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-minus-circle" class="size-4" /> No invoice needed
          </button>
        </div>
        <.no_invoice_form :if={@status in [:missing, :income]} transaction={@transaction} />
      </div>
    </div>
    """
  end

  attr :transaction, :map, required: true

  defp no_invoice_form(assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(%{"id" => assigns.transaction.id, "note" => ""}, as: :exempt)
      )

    ~H"""
    <.form
      for={@form}
      id={"no-invoice-form-#{@transaction.id}"}
      phx-submit="mark_no_invoice"
      class="hidden items-start gap-2"
    >
      <input type="hidden" name="exempt[id]" value={@transaction.id} />
      <div class="flex-1">
        <.input
          field={@form[:note]}
          id={"exempt-note-#{@transaction.id}"}
          type="text"
          placeholder="Reason (optional), e.g. tax payment, dividend, bank fee"
        />
      </div>
      <.button type="submit" class="btn btn-sm btn-primary mt-0.5" phx-disable-with="...">
        Save
      </.button>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :invoice, :map, required: true
  attr :transaction, :map, required: true

  defp suggestion(assigns) do
    cents = assigns.transaction.amount |> Money.cents_from_decimal() |> abs()
    exact? = assigns.invoice.currency == "EUR" and assigns.invoice.amount_cents == cents
    assigns = assign(assigns, exact?: exact?, matched: length(assigns.invoice.transactions))

    ~H"""
    <div id={@id} class="flex items-center gap-3 rounded-lg bg-base-200/60 px-3 py-2 text-sm">
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-2">
          <span class="font-medium">{@invoice.issuer_name}</span>
          <span
            :if={@exact?}
            class="rounded-full bg-emerald-500/10 px-2 text-xs font-medium text-emerald-700 dark:text-emerald-300"
          >
            same amount
          </span>
          <span
            :if={@matched == 0}
            class="rounded-full bg-sky-500/10 px-2 text-xs font-medium text-sky-700 dark:text-sky-300"
          >
            unmatched
          </span>
        </div>
        <div class="text-base-content/60">
          {format_date(@invoice.date)} · <.invoice_amount invoice={@invoice} />
          <span :if={@invoice.number}> · #{@invoice.number}</span>
        </div>
      </div>
      <a
        href={~p"/invoices/#{@invoice.id}/pdf"}
        target="_blank"
        rel="noopener"
        class="text-primary hover:underline"
      >
        PDF
      </a>
      <.button
        id={"attach-existing-#{@invoice.id}"}
        class="btn btn-sm btn-primary btn-soft"
        phx-click="attach_existing"
        phx-value-id={@invoice.id}
      >
        Attach
      </.button>
    </div>
    """
  end
end
