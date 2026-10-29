defmodule IkeEmailsWeb.ReconciliationLive do
  @moduledoc """
  The monthly routine: the transactions of a month, each with the invoices that
  pay for it, and what is still missing.
  """

  use IkeEmailsWeb, :live_view

  require Logger

  import IkeEmailsWeb.InvoiceComponents

  alias IkeEmails.Banking
  alias IkeEmails.Elorus
  alias IkeEmails.InvoiceExtractor
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
     |> assign(:elorus_configured?, Elorus.configured?())
     |> assign(:extract_configured?, InvoiceExtractor.configured?())
     |> assign(:extracting?, false)
     |> assign(:extract_error, nil)
     |> stream(:transactions, [])
     |> stream(:suggestions, [])
     |> reset_elorus()
     |> InvoiceUpload.allow()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = open_transaction(socket, socket.assigns.live_action, params)
    month = month_from(socket.assigns.current_scope, params["month"], socket.assigns.transaction)

    {:noreply, load_month(socket, month)}
  end

  defp open_transaction(socket, :attach, %{"id" => id}) do
    transaction = Banking.get_transaction!(socket.assigns.current_scope, id)
    prefill = Invoicing.new_invoice_for(transaction)

    socket
    |> assign(:transaction, transaction)
    |> assign(:prefill, prefill)
    |> assign(:duplicate, nil)
    |> assign(:pdf_error, nil)
    |> assign(:suggestion_search, "")
    |> assign_form(Invoicing.change_invoice(prefill))
    |> load_suggestions()
    |> reset_elorus()
    |> reset_extract()
  end

  defp open_transaction(socket, _action, _params) do
    socket |> assign(:transaction, nil) |> reset_elorus() |> reset_extract()
  end

  defp month_from(scope, param, transaction) do
    with param when is_binary(param) <- param,
         {:ok, date} <- Date.from_iso8601(param <> "-01") do
      date
    else
      _ -> default_month(scope, transaction)
    end
  end

  defp default_month(_scope, %{date: date}), do: Date.beginning_of_month(date)

  defp default_month(scope, nil) do
    case Banking.months_with_transactions(scope) do
      [latest | _] -> latest
      [] -> Date.beginning_of_month(Date.utc_today())
    end
  end

  defp load_month(socket, month) do
    scope = socket.assigns.current_scope
    transactions = Banking.list_transactions_for_month(scope, month.year, month.month)

    socket
    |> assign(:month, month)
    |> assign(:months, Banking.months_with_transactions(scope))
    |> assign(:summary, Banking.month_summary(transactions))
    |> stream(:transactions, transactions, reset: true)
  end

  defp refresh(socket), do: load_month(socket, socket.assigns.month)

  defp load_suggestions(socket) do
    suggestions =
      Invoicing.suggest_invoices(
        socket.assigns.current_scope,
        socket.assigns.transaction,
        socket.assigns.suggestion_search
      )

    stream(socket, :suggestions, suggestions, reset: true)
  end

  # What the panel knows of Elorus. A search that is still running is forgotten,
  # and its result ignored when it arrives, see handle_info/2. An import is not:
  # it goes on whatever panel is open, and says how it ended when it is done.
  defp reset_elorus(socket) do
    task =
      case socket.assigns[:elorus_task] do
        %{action: :import} = import -> import
        _search_or_none -> nil
      end

    socket
    |> assign(:elorus_task, task)
    |> assign(:elorus_loaded?, false)
    |> assign(:elorus_error, nil)
    |> assign(:elorus_by_id, %{})
    |> assign(:elorus_stored, MapSet.new())
    |> stream(:elorus_invoices, [], reset: true)
  end

  # A PDF that is still being read is forgotten: the result would be for another
  # panel, or for a file that is gone
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
  def handle_event("jump", %{"month" => month}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?month=#{month}")}
  end

  def handle_event("mark_no_invoice", %{"exempt" => %{"id" => id, "note" => note}}, socket) do
    scope = socket.assigns.current_scope
    transaction = Banking.get_transaction!(scope, id)

    case Banking.mark_no_invoice(scope, transaction, note) do
      {:ok, _transaction} ->
        {:noreply, refresh(socket)}

      {:error, :has_invoices} ->
        {:noreply, socket |> put_flash(:error, "That transaction has invoices.") |> refresh()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "The reason is too long.")}
    end
  end

  def handle_event("clear_no_invoice", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    {:ok, _transaction} =
      scope |> Banking.get_transaction!(id) |> then(&Banking.clear_no_invoice(scope, &1))

    {:noreply, refresh(socket)}
  end

  def handle_event(
        "detach",
        %{"invoice-id" => invoice_id, "transaction-id" => transaction_id},
        socket
      ) do
    scope = socket.assigns.current_scope

    :ok =
      Invoicing.detach(
        scope,
        Invoicing.get_invoice!(scope, invoice_id),
        Banking.get_transaction!(scope, transaction_id)
      )

    {:noreply, refresh(socket)}
  end

  def handle_event("validate", %{"invoice" => params}, socket) do
    changeset =
      socket.assigns.prefill |> Invoicing.change_invoice(params) |> Map.put(:action, :validate)

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
      hints = InvoiceUpload.hints(socket.assigns.prefill)

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

  def handle_event("save", %{"invoice" => params}, socket) do
    changeset = Invoicing.change_invoice(socket.assigns.prefill, params)

    with {:valid, true} <- {:valid, changeset.valid?},
         {:ok, {pdf, name}} <- InvoiceUpload.read_pdf(socket) do
      transaction_ids = [socket.assigns.transaction.id]

      socket.assigns.current_scope
      |> Invoicing.create_invoice(params, pdf, name, transaction_ids: transaction_ids)
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
    scope = socket.assigns.current_scope
    invoice = Invoicing.get_invoice!(scope, invoice_id)
    :ok = Invoicing.attach(scope, invoice, socket.assigns.transaction)

    {:noreply,
     socket
     |> put_flash(:info, "Invoice attached.")
     |> push_patch(to: month_path(socket.assigns.month))}
  end

  def handle_event("search_suggestions", %{"q" => term}, socket) do
    {:noreply, socket |> assign(:suggestion_search, term) |> load_suggestions()}
  end

  def handle_event("search_elorus", _params, socket) do
    if elorus_ready?(socket) do
      %{transaction: transaction, month: month} = socket.assigns

      {:noreply,
       start_elorus_task(socket, :search, fn -> Invoicing.search_elorus(transaction, month) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("attach_elorus", %{"id" => id}, socket) do
    with true <- elorus_ready?(socket),
         %Elorus.Invoice{} = invoice <- socket.assigns.elorus_by_id[id] do
      %{transaction: transaction, current_scope: scope} = socket.assigns

      {:noreply,
       start_elorus_task(socket, :import, fn ->
         Invoicing.import_elorus_invoice(scope, invoice, transaction)
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Reading the PDF with AI
  #
  # It takes a few seconds, so it runs in an async task. Another panel or a
  # cancelled upload cancels it, see reset_extract/1.

  @impl true
  def handle_async(:extract, {:ok, {:ok, found}}, socket) when found == %{} do
    {:noreply, extract_failed(socket, :invalid_response)}
  end

  def handle_async(:extract, {:ok, {:ok, found}}, socket) do
    %{prefill: prefill, form: form} = socket.assigns
    params = InvoiceUpload.merge_extracted(form.params, found)
    changeset = prefill |> Invoicing.change_invoice(params) |> Map.put(:action, :validate)

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

  ## Elorus
  #
  # The calls to Elorus and the import of a PDF take a while, so they run in a
  # task of the task supervisor, and the LiveView goes on meanwhile. One at a time.

  defp elorus_ready?(socket) do
    transaction = socket.assigns.transaction

    socket.assigns.elorus_configured? and socket.assigns.elorus_task == nil and
      transaction != nil and income?(transaction)
  end

  defp income?(transaction), do: Decimal.positive?(transaction.amount)

  defp start_elorus_task(socket, action, fun) do
    task = Task.Supervisor.async_nolink(IkeEmails.TaskSupervisor, fun)

    socket
    |> assign(:elorus_task, %{
      ref: task.ref,
      action: action,
      transaction_id: socket.assigns.transaction.id
    })
    |> assign(:elorus_error, nil)
  end

  @impl true
  def handle_info({ref, result}, %{assigns: %{elorus_task: %{ref: ref} = task}} = socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket |> assign(:elorus_task, nil) |> finish_elorus(task, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{elorus_task: %{ref: ref} = task}} = socket
      ) do
    Logger.error("The task for Elorus crashed: #{inspect(reason)}")
    {:noreply, socket |> assign(:elorus_task, nil) |> elorus_failed(task, :crashed)}
  end

  # The result of a search whose panel was closed meanwhile
  def handle_info(_message, socket), do: {:noreply, socket}

  defp finish_elorus(socket, %{action: :search}, {:ok, invoices}) do
    stored =
      Invoicing.imported_elorus_ids(socket.assigns.current_scope, Enum.map(invoices, & &1.id))

    socket
    |> assign(:elorus_loaded?, true)
    |> assign(:elorus_by_id, Map.new(invoices, &{&1.id, &1}))
    |> assign(:elorus_stored, stored)
    |> stream(:elorus_invoices, invoices, reset: true)
  end

  defp finish_elorus(socket, %{action: :import} = task, {:ok, _invoice}) do
    socket = put_flash(socket, :info, "Invoice attached from Elorus.")

    # The panel of the transaction is closed. Another one may be open by now, so
    # only the rows of the month are brought up to date.
    if open_panel?(socket, task),
      do: push_patch(socket, to: month_path(socket.assigns.month)),
      else: refresh(socket)
  end

  defp finish_elorus(socket, task, {:error, reason}), do: elorus_failed(socket, task, reason)
  defp finish_elorus(socket, task, other), do: elorus_failed(socket, task, {:unexpected, other})

  defp elorus_failed(socket, task, reason) do
    message = elorus_error_message(reason)

    if open_panel?(socket, task),
      do: assign(socket, :elorus_error, message),
      else: put_flash(socket, :error, "The invoice from Elorus was not attached. " <> message)
  end

  # Whether the panel of the transaction the task is for is the one that is open
  defp open_panel?(socket, task),
    do: match?(%{id: id} when id == task.transaction_id, socket.assigns.transaction)

  defp elorus_error_message(reason) when reason in [:unauthorized, :forbidden],
    do: "Elorus refused the API key."

  defp elorus_error_message({:rate_limited, seconds}) when is_integer(seconds),
    do: "Elorus is limiting requests. Try again in #{seconds} seconds."

  defp elorus_error_message({:rate_limited, nil}),
    do: "Elorus is limiting requests. Try again in a minute."

  defp elorus_error_message(:business_not_configured),
    do: "Set BUSINESS_NAME to import invoices from Elorus."

  defp elorus_error_message(:not_found), do: "Elorus does not have that invoice any more."

  defp elorus_error_message(:too_large), do: "The PDF from Elorus is larger than 20 MB."

  defp elorus_error_message(:not_a_pdf), do: "Elorus did not return a PDF for that invoice."

  defp elorus_error_message(:invalid_response),
    do: "Elorus answered with something unexpected. Try again later."

  defp elorus_error_message(:too_many_pages),
    do: "Elorus has too many invoices for this month to list."

  defp elorus_error_message(:unknown_transaction),
    do: "The transaction does not exist any more."

  defp elorus_error_message(:invalid_elorus_invoice),
    do: "That invoice has no total or date in Elorus."

  defp elorus_error_message(%Ecto.Changeset{} = changeset) do
    problems =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.map_join(", ", fn {field, messages} ->
        "#{field |> to_string() |> String.replace("_", " ")} #{Enum.join(List.wrap(messages), ", ")}"
      end)

    "The invoice from Elorus cannot be stored: #{problems}."
  end

  defp elorus_error_message({:storage, _reason} = reason) do
    Logger.error("Storing an invoice PDF from Elorus failed: #{inspect(reason)}")
    "The PDF could not be stored. Try again."
  end

  defp elorus_error_message({:unexpected_status, status, _body} = reason) do
    Logger.warning("Elorus failed: #{inspect(reason)}")
    "Elorus answered with an unexpected status (#{status}). Try again later."
  end

  # The request itself failed: a timeout, a refused connection...
  defp elorus_error_message(%{__exception__: true} = exception) do
    Logger.warning("Elorus failed: #{Exception.message(exception)}")
    "Could not reach Elorus. Try again."
  end

  defp elorus_error_message(reason) do
    Logger.warning("Elorus failed: #{inspect(reason)}")
    "Something went wrong with Elorus. Try again."
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
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:reconciliation}>
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
              extract_configured?={@extract_configured?}
              extracting?={@extracting?}
              extract_error={@extract_error}
              submit_label="Save invoice"
            />
          </section>

          <div class="space-y-8">
            <section>
              <h3 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                Attach an existing invoice
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
                  placeholder="Search by issuer, receiver or number"
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

            <section :if={income?(@transaction)} id="elorus-section">
              <h3 class="mb-3 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                Invoices in Elorus
              </h3>
              <.button
                :if={@elorus_configured?}
                id="search-elorus"
                type="button"
                class="btn btn-sm"
                phx-click="search_elorus"
                disabled={@elorus_task != nil}
              >
                <.icon name="hero-magnifying-glass" class="size-4" />
                {if @elorus_task && @elorus_task.action == :search,
                  do: "Searching...",
                  else: "Search #{month_title(@month)}"}
              </.button>
              <p
                :if={!@elorus_configured?}
                id="elorus-unconfigured"
                class="text-sm text-base-content/60"
              >
                Set <code>ELORUS_API_TOKEN</code>
                and <code>ELORUS_ORGANIZATION_ID</code>
                to look up invoices in Elorus.
              </p>
              <p
                :if={@elorus_error}
                id="elorus-error"
                role="alert"
                class="mt-3 rounded-lg bg-error/10 px-3 py-2 text-sm text-error"
              >
                {@elorus_error}
              </p>
              <p
                :if={@elorus_task && @elorus_task.action == :import}
                id="elorus-importing"
                class="mt-3 text-sm text-base-content/60"
              >
                Attaching the invoice from Elorus...
              </p>
              <%!-- The rows of a stream are not drawn again when a task starts or ends, so the
                    container says that one runs, and the buttons follow it with CSS --%>
              <div
                :if={@elorus_loaded?}
                id="elorus-invoices"
                phx-update="stream"
                data-busy={@elorus_task != nil}
                class="group mt-3 space-y-2"
              >
                <p id="elorus-empty" class="hidden text-sm text-base-content/60 only:block">
                  No invoices in Elorus for {month_title(@month)}.
                </p>
                <.elorus_invoice
                  :for={{id, invoice} <- @streams.elorus_invoices}
                  id={id}
                  invoice={invoice}
                  transaction={@transaction}
                  stored={MapSet.member?(@elorus_stored, invoice.id)}
                />
              </div>
            </section>
          </div>
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
          <span :if={invoice.receiver_name} class="text-base-content/60">
            → {invoice.receiver_name}
          </span>
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
  attr :stored, :boolean, required: true

  defp elorus_invoice(assigns) do
    assigns =
      assign(assigns, match?: Invoicing.elorus_match?(assigns.invoice, assigns.transaction))

    ~H"""
    <div id={@id} class="flex items-center gap-3 rounded-lg bg-base-200/60 px-3 py-2 text-sm">
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-2">
          <span class="font-medium">{@invoice.client_name}</span>
          <span
            :if={@match?}
            class="rounded-full bg-emerald-500/10 px-2 text-xs font-medium text-emerald-700 dark:text-emerald-300"
          >
            same amount
          </span>
          <span
            :if={@stored}
            class="rounded-full bg-sky-500/10 px-2 text-xs font-medium text-sky-700 dark:text-sky-300"
          >
            stored
          </span>
        </div>
        <div class="text-base-content/60">
          <span :if={@invoice.date}>{"#{format_date(@invoice.date)} · "}</span>
          <span class="tabular-nums">{elorus_total(@invoice)}</span>
          <span :if={@invoice.representation}>{" · #{@invoice.representation}"}</span>
          <span :if={@invoice.status}>{" · #{@invoice.status}"}</span>
        </div>
      </div>
      <a
        :if={@invoice.permalink}
        href={@invoice.permalink}
        target="_blank"
        rel="noopener noreferrer"
        class="text-primary hover:underline"
      >
        Elorus
      </a>
      <.button
        id={"attach-elorus-#{@invoice.id}"}
        class="btn btn-sm btn-primary btn-soft group-data-[busy]:pointer-events-none group-data-[busy]:opacity-50"
        phx-click="attach_elorus"
        phx-value-id={@invoice.id}
      >
        Attach
      </.button>
    </div>
    """
  end

  defp elorus_total(%{total: %Decimal{} = total, currency_code: currency}),
    do: total |> Money.cents_from_decimal() |> Money.format(currency)

  defp elorus_total(_invoice), do: "-"

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
          <span :if={@invoice.receiver_name} class="text-base-content/60">
            → {@invoice.receiver_name}
          </span>
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
