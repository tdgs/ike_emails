defmodule IkeEmails.Invoicing.Invoice do
  use Ecto.Schema
  import Ecto.Changeset

  alias IkeEmails.Banking.Transaction
  alias IkeEmails.Money

  # The column is a 32 bit integer, 21 million euros is far beyond any invoice
  @max_cents 2_147_483_647

  schema "invoices" do
    field :amount_cents, :integer
    # The amount as typed in the form, `12,50`, parsed into `amount_cents`
    field :amount_input, :string, virtual: true
    field :currency, :string, default: "EUR"
    field :date, :date
    field :issuer_name, :string
    field :issuer_vat, :string
    field :number, :string
    field :notes, :string

    field :file_key, :string
    field :file_name, :string
    field :file_size, :integer
    field :file_sha256, :string

    many_to_many :transactions, Transaction, join_through: "invoice_transactions"

    timestamps(type: :utc_datetime)
  end

  @doc """
  The invoice with its amount filled in the way the form shows it.
  """
  def with_amount_input(%__MODULE__{amount_cents: cents} = invoice) when is_integer(cents) do
    %{invoice | amount_input: Money.format_input(cents)}
  end

  def with_amount_input(invoice), do: invoice

  @doc """
  Changeset of what is typed in. The PDF is not part of it, see `create_changeset/3`.
  """
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [:amount_input, :currency, :date, :issuer_name, :issuer_vat, :number, :notes])
    |> update_change(:currency, &String.upcase(String.trim(&1)))
    |> update_change(:issuer_vat, &normalize_vat/1)
    |> validate_required([:amount_input, :currency, :date, :issuer_name])
    |> validate_format(:currency, ~r/^[A-Z]{3}$/, message: "must be a 3 letter code")
    |> validate_length(:issuer_name, max: 255, count: :codepoints)
    |> validate_length(:issuer_vat, max: 32, count: :codepoints)
    |> validate_length(:number, max: 64, count: :codepoints)
    |> validate_length(:notes, max: 5000)
    |> put_amount_cents()
  end

  @doc """
  Changeset of a new invoice, with the facts of its stored PDF.
  """
  def create_changeset(invoice, attrs, file) do
    invoice
    |> changeset(attrs)
    |> change(Map.take(file, [:file_key, :file_name, :file_size, :file_sha256]))
    |> unique_constraint(:file_sha256, message: "has already been uploaded")
  end

  defp put_amount_cents(changeset) do
    case fetch_change(changeset, :amount_input) do
      {:ok, input} when is_binary(input) ->
        case Money.parse_cents(input) do
          {:ok, cents} when cents > @max_cents ->
            add_error(changeset, :amount_input, "is too large")

          {:ok, cents} when cents > 0 ->
            put_change(changeset, :amount_cents, cents)

          {:ok, _zero} ->
            add_error(changeset, :amount_input, "must be greater than 0")

          :error ->
            add_error(changeset, :amount_input, "is invalid")
        end

      _ ->
        changeset
    end
  end

  # Spaces, dots and dashes are formatting: "EL 094 019.245" is "EL094019245"
  defp normalize_vat(nil), do: nil

  defp normalize_vat(vat) do
    case vat |> String.replace(~r/[\s.\-]/u, "") |> String.upcase() do
      "" -> nil
      normalized -> normalized
    end
  end
end
