defmodule IkeEmails.Repo.Migrations.AddReceiverAndElorusIdToInvoices do
  use Ecto.Migration

  def change do
    alter table(:invoices) do
      # The other party of an invoice that you issued: the issuer is you
      add :receiver_name, :string
      add :receiver_vat, :string
      # The invoice this one was imported from, so it is imported only once
      add :elorus_id, :string
    end

    create unique_index(:invoices, [:elorus_id])
  end
end
