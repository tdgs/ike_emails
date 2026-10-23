defmodule IkeEmails.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  def change do
    create table(:invoices) do
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false, default: "EUR"
      add :date, :date, null: false
      add :issuer_name, :string, null: false
      add :issuer_vat, :string
      add :number, :string
      add :notes, :text

      add :file_key, :string, null: false
      add :file_name, :string, null: false
      add :file_size, :integer, null: false
      add :file_sha256, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # The same PDF is stored once
    create unique_index(:invoices, [:file_sha256])
    create index(:invoices, [:date])
    create index(:invoices, [:issuer_name])
  end
end
