defmodule IkeEmails.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :date, :date, null: false
      add :value_date, :date, null: false
      add :description, :string, null: false
      add :branch, :string
      add :transaction_id, :string, null: false
      add :amount, :decimal, precision: 15, scale: 2, null: false
      add :conversion_details, :text
      add :sender_details, :text
      add :additional_information, :text

      timestamps(type: :utc_datetime)
    end

    # The bank books a transfer and its fee under the same transaction id, so
    # the id alone is not unique.
    create unique_index(:transactions, [:transaction_id, :amount, :description])
    create index(:transactions, [:date])
  end
end
