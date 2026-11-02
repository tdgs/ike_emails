defmodule IkeEmails.Settings.UserSettings do
  use Ecto.Schema
  import Ecto.Changeset

  alias IkeEmails.Invoicing.Invoice

  schema "user_settings" do
    # Who the user is as the issuer of the invoices imported from Elorus
    field :business_name, :string
    field :business_vat, :string

    field :elorus_organization_id, :string
    field :elorus_demo, :boolean, default: false

    # The API key of Elorus, sealed by IkeEmails.Settings.SealedToken. It is never
    # selected when the settings are read, see IkeEmails.Settings.get_settings/1
    field :elorus_token_sealed, :string, redact: true
    field :elorus_token_salt, :string
    # Whether a key is stored, which is all the pages need to know
    field :elorus_token_set, :boolean, virtual: true, default: false

    belongs_to :user, IkeEmails.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset of what is typed in on the settings page. The API key is not part of
  it, see `token_changeset/3`.
  """
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:business_name, :business_vat, :elorus_organization_id, :elorus_demo])
    |> update_change(:business_name, &trim/1)
    |> update_change(:business_vat, &Invoice.normalize_vat/1)
    |> update_change(:elorus_organization_id, &trim/1)
    # The name is put in the prompt of the language model, on one line
    |> validate_length(:business_name, max: 160, count: :codepoints)
    |> validate_format(:business_name, ~r/\A[^\p{Cc}\p{Zl}\p{Zp}]*\z/u,
      message: "must not have control characters or line breaks"
    )
    |> validate_length(:business_vat, max: 32, count: :codepoints)
    |> validate_length(:elorus_organization_id, max: 64)
    |> validate_format(:elorus_organization_id, ~r/\A[A-Za-z0-9_-]+\z/,
      message: "must be made of letters, digits, - and _"
    )
    |> unique_constraint(:user_id)
  end

  # Blank is not set. Cast has made the value nil already when it was only spaces
  defp trim(nil), do: nil

  defp trim(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Changeset that stores the sealed API key, and its salt.
  """
  def token_changeset(settings, sealed, salt) do
    change(settings, elorus_token_sealed: sealed, elorus_token_salt: salt)
  end
end
