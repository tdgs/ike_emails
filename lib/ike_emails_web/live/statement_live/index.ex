defmodule IkeEmailsWeb.StatementLive.Index do
  @moduledoc """
  The bank statements the crawler sent, a PDF for each month.
  """

  use IkeEmailsWeb, :live_view

  alias IkeEmails.Statements

  @impl true
  def mount(_params, _session, socket) do
    statements = Statements.list_statements(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Statements")
     |> stream(:statements, statements)}
  end

  defp month_title(month), do: Calendar.strftime(month, "%B %Y")
  defp format_date(datetime), do: Calendar.strftime(datetime, "%d/%m/%Y")

  defp format_size(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_000_000, do: "#{round(bytes / 1_000)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:statements}>
      <.header>
        Statements
        <:subtitle>The bank statement of each month, as the bank crawler sent it.</:subtitle>
      </.header>

      <div
        id="statements"
        phx-update="stream"
        class="divide-y divide-base-300 overflow-hidden rounded-2xl bg-base-100 ring-1 ring-base-300"
      >
        <div
          id="statements-empty"
          class="hidden px-6 py-12 text-center text-base-content/60 only:block"
        >
          No statements yet.
        </div>
        <div
          :for={{id, statement} <- @streams.statements}
          id={id}
          class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-4 sm:px-6"
        >
          <.icon name="hero-document-text" class="size-6 shrink-0 text-primary" />
          <div class="min-w-0 flex-1 basis-56">
            <div class="font-medium">{month_title(statement.month)}</div>
            <div class="truncate text-sm text-base-content/60">
              {statement.file_name} · {format_size(statement.file_size)}
            </div>
          </div>
          <div class="text-sm tabular-nums text-base-content/60">
            Received {format_date(statement.updated_at)}
          </div>
          <a
            href={~p"/statements/#{statement.id}/pdf"}
            target="_blank"
            rel="noopener"
            id={"pdf-#{statement.id}"}
            class="rounded-lg px-2.5 py-1 text-sm font-medium text-primary transition-colors hover:bg-primary/10"
          >
            PDF
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
