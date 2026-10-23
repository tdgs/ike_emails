defmodule IkeEmails.Banking.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  alias IkeEmails.Invoicing.Invoice

  @required [:date, :value_date, :description, :transaction_id, :amount]
  @optional [:branch, :conversion_details, :sender_details, :additional_information]

  schema "transactions" do
    field :date, :date
    field :value_date, :date
    field :description, :string
    field :branch, :string
    field :transaction_id, :string
    field :amount, :decimal
    field :conversion_details, :string
    field :sender_details, :string
    field :additional_information, :string
    # The bank line needs no invoice (tax, dividends, fees, ...), optionally with the reason
    field :no_invoice, :boolean, default: false
    field :no_invoice_note, :string

    many_to_many :invoices, Invoice, join_through: "invoice_transactions"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts a transaction as the bank crawler pushes it. Blank optional fields are
  stored as `nil`.
  """
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end

  @doc """
  Marks the transaction as one that needs no invoice. The reason is optional, and
  a blank one is stored as `nil`.
  """
  def no_invoice_changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:no_invoice_note])
    |> validate_length(:no_invoice_note, max: 1000)
    |> put_change(:no_invoice, true)
  end

  @doc """
  Takes the "needs no invoice" mark, and its reason, off the transaction.
  """
  def clear_no_invoice_changeset(transaction) do
    change(transaction, no_invoice: false, no_invoice_note: nil)
  end
end
