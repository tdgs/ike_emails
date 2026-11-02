defmodule IkeEmails.Repo.Migrations.CreateStatements do
  use Ecto.Migration

  def change do
    create table(:statements) do
      # The first day of the month the bank statement is for
      add :month, :date, null: false

      add :file_key, :string, null: false
      add :file_name, :string, null: false
      add :file_size, :integer, null: false
      add :file_sha256, :string, null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # A user has one statement per month: a new PDF for the month replaces the old one
    create unique_index(:statements, [:user_id, :month])
  end
end
