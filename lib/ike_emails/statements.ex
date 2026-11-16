defmodule IkeEmails.Statements do
  @moduledoc """
  The bank statements: one PDF per month, per user.
  """

  import Ecto.Query, warn: false

  require Logger

  alias IkeEmails.Accounts.Scope
  alias IkeEmails.Repo
  alias IkeEmails.Statements.Statement
  alias IkeEmails.Storage

  @pdf_url_ttl 300

  @doc """
  The statements of the user, the latest month first.
  """
  def list_statements(%Scope{} = scope) do
    Statement
    |> where([s], s.user_id == ^Scope.user_id(scope))
    |> order_by([s], desc: s.month)
    |> Repo.all()
  end

  @doc """
  Gets a statement of the user. Raises when there is none, which is also the case
  for the statement of another user.
  """
  def get_statement!(%Scope{} = scope, id) do
    Repo.get_by!(Statement, id: id, user_id: Scope.user_id(scope))
  end

  @doc """
  The statement of the user for the month (a date in it), or `nil`.
  """
  def get_statement(%Scope{} = scope, %Date{} = month) do
    Repo.get_by(Statement, user_id: Scope.user_id(scope), month: Date.beginning_of_month(month))
  end

  @doc """
  Stores the PDF as the statement of the month, which is typed `YYYY-MM`. The
  month has one statement: a different PDF replaces the one it had, and its
  object is deleted from the storage. The same PDF again changes nothing.

  Returns `{:ok, :created | :replaced | :existing, statement}`. Errors: a
  changeset (the month is invalid), `:not_a_pdf`, `:too_large` and
  `{:storage, reason}`.
  """
  def put_statement(%Scope{} = scope, month, pdf, file_name) when is_binary(pdf) do
    with :ok <- Storage.check_pdf(pdf),
         {:ok, date} <- parse_month(month) do
      file = file_facts(scope, date, pdf, file_name)

      case get_statement(scope, date) do
        %Statement{file_sha256: sha256} = statement when sha256 == file.file_sha256 ->
          {:ok, :existing, statement}

        existing ->
          save(scope, month, existing, file, pdf)
      end
    end
  end

  @doc """
  A temporary URL to download the PDF of the statement.
  """
  def pdf_url(%Statement{file_key: key}), do: Storage.presigned_url(key, @pdf_url_ttl)

  defp parse_month(month) do
    case Statement.parse_month(month) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, %{Statement.changeset(%Statement{}, month, %{}) | action: :insert}}
    end
  end

  # The key has the month and the hash of the PDF: replacing a statement never
  # overwrites its object, so a failure half way leaves the old one as it was
  defp file_facts(scope, month, pdf, file_name) do
    sha256 = :crypto.hash(:sha256, pdf) |> Base.encode16(case: :lower)

    %{
      file_key:
        "statements/#{Scope.user_id(scope)}/#{Calendar.strftime(month, "%Y-%m")}-#{sha256}.pdf",
      file_name:
        file_name |> Path.basename() |> String.codepoints() |> Enum.take(255) |> Enum.join(),
      file_size: byte_size(pdf),
      file_sha256: sha256
    }
  end

  defp save(scope, month, existing, file, pdf) do
    changeset =
      Statement.changeset(existing || %Statement{user_id: Scope.user_id(scope)}, month, file)

    with :ok <- store(file, pdf) do
      case Repo.insert_or_update(changeset) do
        {:ok, statement} ->
          delete_replaced(existing)
          {:ok, saved(existing), statement}

        {:error, _changeset} = error ->
          remove_orphan(file)
          error
      end
    end
  end

  defp saved(nil), do: :created
  defp saved(%Statement{}), do: :replaced

  # The row first, the object second: the statement never points at a deleted PDF
  defp delete_replaced(nil), do: :ok
  defp delete_replaced(%Statement{file_key: key}), do: delete_object(key)

  defp store(file, pdf) do
    case Storage.put(file.file_key, pdf, "application/pdf") do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  # The key is the user, the month and the hash of the PDF: it is only an orphan
  # if no statement has it, one stored in the meantime owns it
  defp remove_orphan(file) do
    unless Repo.exists?(from s in Statement, where: s.file_key == ^file.file_key) do
      delete_object(file.file_key)
    end
  end

  defp delete_object(key) do
    case Storage.delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not delete #{key} from storage: #{inspect(reason)}")
    end
  end
end
