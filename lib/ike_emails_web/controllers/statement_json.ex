defmodule IkeEmailsWeb.StatementJSON do
  alias IkeEmails.Statements.Statement
  alias IkeEmailsWeb.CoreComponents

  def show(%{statement: statement}) do
    %{data: data(statement)}
  end

  def error(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)}
  end

  def error(%{errors: errors}) do
    %{errors: errors}
  end

  defp data(%Statement{} = statement) do
    %{
      id: statement.id,
      month: Calendar.strftime(statement.month, "%Y-%m"),
      file_name: statement.file_name,
      file_size: statement.file_size,
      file_sha256: statement.file_sha256,
      inserted_at: statement.inserted_at,
      updated_at: statement.updated_at
    }
  end
end
