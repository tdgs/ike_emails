defmodule IkeEmailsWeb.TransactionJSON do
  alias IkeEmails.Banking.Transaction
  alias IkeEmailsWeb.CoreComponents

  def show(%{transaction: transaction}) do
    %{data: data(transaction)}
  end

  def error(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)}
  end

  defp data(%Transaction{} = transaction) do
    %{
      id: transaction.id,
      date: transaction.date,
      value_date: transaction.value_date,
      description: transaction.description,
      branch: transaction.branch,
      transaction_id: transaction.transaction_id,
      amount: Decimal.to_string(transaction.amount, :normal),
      conversion_details: transaction.conversion_details,
      sender_details: transaction.sender_details,
      additional_information: transaction.additional_information
    }
  end
end
