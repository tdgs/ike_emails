defmodule IkeEmails.Repo.Migrations.AddUserIdToTransactionsAndInvoices do
  use Ecto.Migration

  def up do
    # Rows without an owner cannot be kept: what was stored before the users is thrown away
    execute "DELETE FROM invoice_transactions"
    execute "DELETE FROM invoices"
    execute "DELETE FROM transactions"

    alter table(:transactions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    alter table(:invoices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    # What was unique is now unique per user: two users can have the same bank
    # line, the same PDF, or the same Elorus invoice
    drop unique_index(:transactions, [:transaction_id, :amount, :description])
    create unique_index(:transactions, [:user_id, :transaction_id, :amount, :description])

    drop unique_index(:invoices, [:file_sha256])
    create unique_index(:invoices, [:user_id, :file_sha256])

    drop unique_index(:invoices, [:elorus_id])
    create unique_index(:invoices, [:user_id, :elorus_id])

    drop index(:transactions, [:date])
    create index(:transactions, [:user_id, :date])

    drop index(:invoices, [:date])
    create index(:invoices, [:user_id, :date])
  end

  def down do
    drop index(:invoices, [:user_id, :date])
    create index(:invoices, [:date])

    drop index(:transactions, [:user_id, :date])
    create index(:transactions, [:date])

    drop unique_index(:invoices, [:user_id, :elorus_id])
    drop unique_index(:invoices, [:user_id, :file_sha256])
    drop unique_index(:transactions, [:user_id, :transaction_id, :amount, :description])

    # The owners are gone, and so is what they owned: the same rows may repeat across users
    execute "DELETE FROM invoice_transactions"
    execute "DELETE FROM invoices"
    execute "DELETE FROM transactions"

    create unique_index(:invoices, [:elorus_id])
    create unique_index(:invoices, [:file_sha256])
    create unique_index(:transactions, [:transaction_id, :amount, :description])

    alter table(:invoices) do
      remove :user_id
    end

    alter table(:transactions) do
      remove :user_id
    end
  end
end
