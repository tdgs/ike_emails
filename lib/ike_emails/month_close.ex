defmodule IkeEmails.MonthClose do
  @moduledoc """
  Closing a month with the help of a language model: an agent
  (`IkeEmails.MonthClose.Agent`) looks for the invoice of every open transaction of
  the month, and leaves a proposal (`IkeEmails.MonthClose.Proposal`) on the ones it
  can settle. A proposal changes nothing until the user approves it.

  The model is the one of `AI_MODEL`, see `config/runtime.exs`. A run sends the
  open transactions of the month to its provider, and the facts (not the PDFs) of
  the invoices that may fit them.
  """

  import Ecto.Query, warn: false

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Banking
  alias IkeEmails.Banking.Transaction
  alias IkeEmails.Elorus
  alias IkeEmails.Invoicing
  alias IkeEmails.MonthClose.Agent
  alias IkeEmails.MonthClose.Proposal
  alias IkeEmails.Repo
  alias IkeEmails.Settings

  @doc """
  Whether a model is set.
  """
  def configured? do
    :ike_emails |> Application.get_env(__MODULE__, []) |> Keyword.get(:model) |> present?()
  end

  defp present?(value), do: value not in [nil, ""]

  @doc """
  Runs the agent for the open transactions of the month of the user: the ones
  with no invoice that are not marked as needing none. The proposals they had are
  dropped first.

  Elorus is searched only when the user has unlocked it. Returns
  `{:ok, %{proposed: count, elorus_skipped?: boolean}}`, where `elorus_skipped?`
  tells that there was income, and Elorus is set up but locked. Or
  `{:error, reason}`: `:not_configured`, or what `IkeEmails.LLM.reason/1` returns,
  and then the proposals made before the error stay.
  """
  def run(%Scope{} = scope, %Date{} = month) do
    if configured?() do
      open =
        scope
        |> Banking.list_transactions_for_month(month.year, month.month)
        |> Enum.filter(&(Banking.status(&1) in [:missing, :income]))

      ids = Enum.map(open, & &1.id)
      Repo.delete_all(from p in Proposal, where: p.transaction_id in ^ids)

      unlocked? = Elorus.Connection.unlocked?(scope)

      skipped? =
        not unlocked? and Settings.elorus_configured?(scope) and
          Enum.any?(open, &Decimal.positive?(&1.amount))

      with {:ok, proposed} <- run_agent(scope, month, open, unlocked?) do
        {:ok, %{proposed: length(proposed), elorus_skipped?: skipped?}}
      end
    else
      {:error, :not_configured}
    end
  end

  defp run_agent(_scope, _month, [], _elorus?), do: {:ok, []}
  defp run_agent(scope, month, open, elorus?), do: Agent.run(scope, month, open, elorus?)

  @doc false
  # Stores what the agent proposes for a transaction, in place of the proposal it
  # has. `target` is what the agent checked: `%{invoice_id: id}`,
  # `%{elorus_invoice: raw}` or `%{}`. `attrs` is what the model said.
  def put_proposal(%Scope{} = scope, %Transaction{} = transaction, target, attrs) do
    Scope.authorize!(scope, transaction)

    %Proposal{user_id: Scope.user_id(scope), transaction_id: transaction.id}
    |> struct!(target)
    |> Proposal.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :transaction_id
    )
  end

  @doc """
  Gets a proposal of the user, or `nil` when there is none (any more), which is
  also the case for the proposal of another user.
  """
  def get_proposal(%Scope{} = scope, id) do
    Repo.get_by(Proposal, id: id, user_id: Scope.user_id(scope))
  end

  @doc """
  Does what the proposal says, and drops it. Importing from Elorus downloads the
  PDF, so it takes a while and needs Elorus unlocked.

  Returns `:ok`, or `{:error, reason}` with the error of
  `IkeEmails.Invoicing.attach/3`, `IkeEmails.Invoicing.import_elorus_invoice/3` or
  `IkeEmails.Banking.mark_no_invoice/3`, and then the proposal stays.
  """
  def approve(%Scope{} = scope, %Proposal{} = proposal) do
    Scope.authorize!(scope, proposal)
    transaction = Banking.get_transaction!(scope, proposal.transaction_id)

    with :ok <- carry_out(scope, proposal, transaction) do
      reject(scope, proposal)
    end
  end

  defp carry_out(scope, %Proposal{kind: :attach} = proposal, transaction) do
    Invoicing.attach(scope, Invoicing.get_invoice!(scope, proposal.invoice_id), transaction)
  end

  defp carry_out(scope, %Proposal{kind: :import_elorus} = proposal, transaction) do
    invoice = Elorus.Invoice.from_api(proposal.elorus_invoice)
    with {:ok, _invoice} <- Invoicing.import_elorus_invoice(scope, invoice, transaction), do: :ok
  end

  defp carry_out(scope, %Proposal{kind: :no_invoice} = proposal, transaction) do
    with {:ok, _transaction} <- Banking.mark_no_invoice(scope, transaction, proposal.note),
         do: :ok
  end

  @doc """
  Drops the proposal. Doing it twice is fine.
  """
  def reject(%Scope{} = scope, %Proposal{} = proposal) do
    Scope.authorize!(scope, proposal)
    Repo.delete_all(from p in Proposal, where: p.id == ^proposal.id)
    :ok
  end
end
