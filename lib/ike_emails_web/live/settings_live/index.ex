defmodule IkeEmailsWeb.SettingsLive.Index do
  @moduledoc """
  The settings of the user: their business, and the Elorus account the invoices
  they issued are read from.

  The Elorus API key has a form of its own, with the password of the user, which
  seals it (see `IkeEmails.Settings`). Neither is a field of a form that is sent
  back to the page, and both have top level names (`api_token`, `password`), which
  is how the logs know to filter them. Nothing is assigned of them, flashed or
  rendered again, and the form is only submitted, never validated as it is typed:
  that would send the key with every keystroke.
  """

  use IkeEmailsWeb, :live_view

  alias IkeEmails.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:token_error, nil)
     |> assign_settings()}
  end

  # The settings are read without the sealed key, only whether there is one
  defp assign_settings(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:settings, Settings.get_settings(scope))
    |> assign_form(Settings.change_settings(scope))
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :settings))
  end

  ## Events

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    case Settings.update_settings(socket.assigns.current_scope, params) do
      {:ok, _settings} ->
        {:noreply, socket |> put_flash(:info, "Settings saved.") |> assign_settings()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  def handle_event("save_token", %{"api_token" => token, "password" => password}, socket)
      when is_binary(token) and is_binary(password) do
    case Settings.set_elorus_token(socket.assigns.current_scope, token, password) do
      {:ok, _settings} ->
        # The page is made again, so that what was typed is gone from it
        {:noreply,
         socket
         |> put_flash(:info, "Elorus API key saved.")
         |> push_navigate(to: ~p"/settings")}

      {:error, reason} ->
        {:noreply, assign(socket, :token_error, token_error_message(reason))}
    end
  end

  # What is sent is not shown, as it is not a form of ours
  def handle_event("save_token", _params, socket) do
    {:noreply, assign(socket, :token_error, token_error_message(:invalid_form))}
  end

  def handle_event("clear_token", _params, socket) do
    :ok = Settings.clear_elorus_token(socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:token_error, nil)
     |> put_flash(:info, "Elorus API key removed.")
     |> assign_settings()}
  end

  defp token_error_message(:invalid_password), do: "That password is not right."

  defp token_error_message(:invalid_token),
    do: "That does not look like an API key: it has 8 to 200 characters, and no spaces."

  defp token_error_message(_other), do: "The API key could not be saved. Try again."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <.header>
        Settings
        <:subtitle>Who you are, and where your invoices are issued.</:subtitle>
      </.header>

      <section class="rounded-2xl bg-base-100 p-6 ring-1 ring-base-300">
        <.form for={@form} id="settings-form" phx-submit="save" class="space-y-6">
          <div class="space-y-2">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Business
            </h2>
            <p class="text-sm text-base-content/70">
              The invoices you issue are the ones with this business as the issuer. It is
              also told to the AI that reads an invoice, to tell them from those you received.
            </p>
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input
                field={@form[:business_name]}
                id="settings-business-name"
                type="text"
                label="Name"
                autocomplete="organization"
              />
              <.input
                field={@form[:business_vat]}
                id="settings-business-vat"
                type="text"
                label="VAT number"
                autocomplete="off"
              />
            </div>
          </div>

          <div class="space-y-2">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Elorus
            </h2>
            <p class="text-sm text-base-content/70">
              The organization to look up the invoices in. Changing it locks the API key again.
            </p>
            <.input
              field={@form[:elorus_organization_id]}
              id="settings-elorus-organization-id"
              type="text"
              label="Organization ID"
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={@form[:elorus_demo]}
              id="settings-elorus-demo"
              type="checkbox"
              label="Use the Elorus demo environment"
            />
          </div>

          <.button id="save-settings" class="btn btn-primary" phx-disable-with="Saving...">
            Save settings
          </.button>
        </.form>
      </section>

      <section class="space-y-4 rounded-2xl bg-base-100 p-6 ring-1 ring-base-300">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Elorus API key
            </h2>
            <span
              id="elorus-token-status"
              class={[
                "inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-medium",
                if(@settings.elorus_token_set,
                  do: "bg-success/10 text-success",
                  else: "bg-base-200 text-base-content/60"
                )
              ]}
            >
              <.icon
                name={if(@settings.elorus_token_set, do: "hero-lock-closed", else: "hero-lock-open")}
                class="size-3.5"
              />
              {if @settings.elorus_token_set, do: "Key saved", else: "No key"}
            </span>
          </div>
          <.button
            :if={@settings.elorus_token_set}
            id="clear-elorus-token"
            type="button"
            class="btn btn-sm btn-ghost text-error"
            phx-click="clear_token"
            data-confirm="Remove the Elorus API key? You will have to enter it again to use Elorus."
          >
            <.icon name="hero-trash" class="size-4" /> Remove key
          </.button>
        </div>

        <p class="text-sm text-base-content/70">
          The key is sealed with your password, and is never shown again. To use Elorus you
          enter your password, which unlocks the key for a while: it locks again when it is
          not used, when you log out and when the server restarts. A key you save replaces
          the one there is.
        </p>

        <%!-- No field=, so that what is typed is never sent back to the page, and the names
              are top level, which is how the logs know to leave them out. No phx-change:
              it would send them with every keystroke --%>
        <.form for={to_form(%{})} id="elorus-token-form" phx-submit="save_token" class="space-y-2">
          <div class="grid gap-x-4 sm:grid-cols-2">
            <.input
              type="password"
              name="api_token"
              id="settings-api-token"
              label="API key"
              value=""
              autocomplete="off"
              spellcheck="false"
              required
            />
            <.input
              type="password"
              name="password"
              id="settings-password"
              label="Your password, used to seal the key"
              value=""
              autocomplete="current-password"
              required
            />
          </div>
          <p
            :if={@token_error}
            id="elorus-token-error"
            role="alert"
            class="rounded-lg bg-error/10 px-3 py-2 text-sm text-error"
          >
            {@token_error}
          </p>
          <.button id="save-elorus-token" class="btn btn-primary" phx-disable-with="Sealing...">
            <.icon name="hero-lock-closed" class="size-4" /> Save key
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
