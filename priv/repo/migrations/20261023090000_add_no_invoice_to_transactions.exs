defmodule IkeEmails.Repo.Migrations.AddNoInvoiceToTransactions do
  use Ecto.Migration

  def up do
    alter table(:transactions) do
      add :no_invoice, :boolean, null: false, default: false
    end

    # Until now a note was what marked a transaction as needing no invoice
    # (a blank note is the placeholder `down` leaves for a mark without a reason)
    execute """
    UPDATE transactions
    SET no_invoice = true, no_invoice_note = NULLIF(btrim(no_invoice_note), '')
    WHERE no_invoice_note IS NOT NULL
    """
  end

  def down do
    # A transaction marked without a reason keeps a note, so the mark survives
    execute "UPDATE transactions SET no_invoice_note = '' WHERE no_invoice AND no_invoice_note IS NULL"

    alter table(:transactions) do
      remove :no_invoice
    end
  end
end
