defmodule IkeEmails.Repo.Migrations.CreateInvoiceTransactionsAndExemptions do
  use Ecto.Migration

  def change do
    create table(:invoice_transactions, primary_key: false) do
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :transaction_id, references(:transactions, on_delete: :delete_all), null: false
    end

    create unique_index(:invoice_transactions, [:invoice_id, :transaction_id])
    create index(:invoice_transactions, [:transaction_id])

    # Set when the bank line needs no invoice (tax, dividends, fees, ...), with the reason
    alter table(:transactions) do
      add :no_invoice_note, :text
    end
  end
end
