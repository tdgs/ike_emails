defmodule IkeEmails.Repo.Migrations.CreateProposals do
  use Ecto.Migration

  def change do
    create table(:proposals) do
      add :transaction_id, references(:transactions, on_delete: :delete_all), null: false

      # attach, import_elorus or no_invoice
      add :kind, :string, null: false

      # The invoice to attach, for an attach
      add :invoice_id, references(:invoices, on_delete: :delete_all)
      # The invoice as the Elorus API returned it, for an import_elorus
      add :elorus_invoice, :map
      # The reason, for a no_invoice
      add :note, :text
      # Why the model proposes this, shown to the user
      add :rationale, :text, null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # A transaction has one open proposal: a new one replaces it
    create unique_index(:proposals, [:transaction_id])
  end
end
