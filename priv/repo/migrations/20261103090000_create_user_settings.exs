defmodule IkeEmails.Repo.Migrations.CreateUserSettings do
  use Ecto.Migration

  def change do
    create table(:user_settings) do
      # Who the user is as the issuer of the invoices imported from Elorus
      add :business_name, :string
      add :business_vat, :string

      add :elorus_organization_id, :string
      add :elorus_demo, :boolean, null: false, default: false

      # The API key of Elorus, sealed with the login password of the user and a key
      # of the server (IkeEmails.Settings.SealedToken), so a dump of the database
      # holds no key. The salt is not a secret
      add :elorus_token_sealed, :text
      add :elorus_token_salt, :string

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # A user has one row of settings
    create unique_index(:user_settings, [:user_id])
  end
end
