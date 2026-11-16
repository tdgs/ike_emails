defmodule IkeEmails.MonthClose.Proposal do
  @moduledoc """
  What the month-close agent proposes for a transaction: attach an invoice the
  user has, import one from Elorus, or mark it as needing no invoice. It changes
  nothing until the user approves it, see `IkeEmails.MonthClose`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "proposals" do
    field :kind, Ecto.Enum, values: [:attach, :import_elorus, :no_invoice]
    # The invoice as the Elorus API returned it, for an import_elorus
    field :elorus_invoice, :map
    # The reason, for a no_invoice
    field :note, :string
    field :rationale, :string

    belongs_to :user, IkeEmails.Accounts.User
    belongs_to :transaction, IkeEmails.Banking.Transaction
    belongs_to :invoice, IkeEmails.Invoicing.Invoice

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts what the model says of a proposal. Whose it is and what it points to are
  set on the struct.
  """
  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [:kind, :note, :rationale])
    |> validate_required([:kind, :rationale])
    |> validate_length(:note, max: 1000)
    |> validate_length(:rationale, max: 1000)
  end
end
