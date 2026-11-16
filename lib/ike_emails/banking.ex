defmodule IkeEmails.Banking do
  @moduledoc """
  The bank transactions pushed by the bank crawler.
  """

  import Ecto.Query, warn: false

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Banking.Transaction
  alias IkeEmails.Repo

  # The bank books a transfer and its fee under one transaction id, so a
  # transaction is told apart by its amount and description as well. Two users
  # can have the same bank line.
  @key [:user_id, :transaction_id, :amount, :description]

  @doc """
  Returns all the transactions of the user, newest first.
  """
  def list_transactions(%Scope{} = scope) do
    Repo.all(
      from t in Transaction,
        where: t.user_id == ^Scope.user_id(scope),
        order_by: [desc: t.date, desc: t.id]
    )
  end

  @doc """
  Gets a transaction of the user with its invoices. Raises when there is none,
  which is also the case for the transaction of another user.
  """
  def get_transaction!(%Scope{} = scope, id) do
    Transaction
    |> Repo.get_by!(id: id, user_id: Scope.user_id(scope))
    |> Repo.preload(:invoices)
  end

  @doc """
  The transactions of the user booked in a month, oldest first, with their invoices
  and what the month-close agent proposes for them.
  """
  def list_transactions_for_month(%Scope{} = scope, year, month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    Repo.all(
      from t in Transaction,
        where: t.user_id == ^Scope.user_id(scope),
        where: t.date >= ^first and t.date <= ^last,
        order_by: [asc: t.date, asc: t.transaction_id, asc: t.id],
        preload: [:invoices, proposal: :invoice]
    )
  end

  @doc """
  The first days of the months that have transactions of the user, latest first.
  """
  def months_with_transactions(%Scope{} = scope) do
    Repo.all(
      from t in Transaction,
        where: t.user_id == ^Scope.user_id(scope),
        distinct: true,
        select: fragment("date_trunc('month', ?)::date", t.date),
        order_by: [desc: fragment("date_trunc('month', ?)::date", t.date)]
    )
  end

  @doc """
  Where a transaction stands in the reconciliation, from its loaded invoices:

    * `:invoiced` - it has at least one invoice
    * `:exempt` - it was marked as needing no invoice
    * `:missing` - money out, without either
    * `:income` - money in, without either
  """
  def status(%Transaction{invoices: %Ecto.Association.NotLoaded{}}) do
    raise ArgumentError, "the invoices of the transaction must be preloaded"
  end

  def status(%Transaction{invoices: [_ | _]}), do: :invoiced
  def status(%Transaction{no_invoice: true}), do: :exempt

  def status(%Transaction{amount: amount}) do
    if Decimal.negative?(amount), do: :missing, else: :income
  end

  @doc """
  Counts the transactions per status, and the total of the missing ones in cents.
  """
  def month_summary(transactions) do
    base = %{invoiced: 0, exempt: 0, missing: 0, income: 0, missing_cents: 0}

    Enum.reduce(transactions, base, fn transaction, summary ->
      status = status(transaction)
      summary = Map.update!(summary, status, &(&1 + 1))

      case status do
        :missing ->
          cents = transaction.amount |> IkeEmails.Money.cents_from_decimal() |> abs()
          Map.update!(summary, :missing_cents, &(&1 + cents))

        _ ->
          summary
      end
    end)
  end

  @doc """
  Marks a transaction as one that needs no invoice, optionally with the reason.
  A transaction that has invoices cannot be marked.
  """
  def mark_no_invoice(scope, transaction, note \\ nil)

  def mark_no_invoice(%Scope{} = scope, %Transaction{invoices: [_ | _]} = transaction, _note) do
    Scope.authorize!(scope, transaction)
    {:error, :has_invoices}
  end

  def mark_no_invoice(%Scope{} = scope, %Transaction{} = transaction, note) do
    scope
    |> Scope.authorize!(transaction)
    |> Transaction.no_invoice_changeset(%{no_invoice_note: note})
    |> Repo.update()
  end

  @doc """
  Takes the "needs no invoice" mark, and its reason, off a transaction.
  """
  def clear_no_invoice(%Scope{} = scope, %Transaction{} = transaction) do
    scope
    |> Scope.authorize!(transaction)
    |> Transaction.clear_no_invoice_changeset()
    |> Repo.update()
  end

  @doc """
  Stores a transaction of the user. Pushing one that is already stored is not an
  error: the stored transaction is returned as `:existing`, so the crawler can
  safely push a whole statement again.
  """
  def create_transaction(%Scope{} = scope, attrs) do
    changeset = Transaction.changeset(%Transaction{user_id: Scope.user_id(scope)}, attrs)

    with {:ok, transaction} <-
           Repo.insert(changeset, on_conflict: :nothing, conflict_target: @key) do
      case transaction.id do
        nil -> {:ok, :existing, get_by_key!(changeset)}
        _id -> {:ok, :created, transaction}
      end
    end
  end

  defp get_by_key!(changeset) do
    Repo.get_by!(Transaction, Enum.map(@key, &{&1, Ecto.Changeset.get_field(changeset, &1)}))
  end
end
