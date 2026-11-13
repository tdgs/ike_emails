defmodule IkeEmailsWeb.MonthReportController do
  use IkeEmailsWeb, :controller

  require Logger

  alias IkeEmails.Reports
  alias IkeEmails.Statements.Statement

  @doc """
  The zip of a month, typed `YYYY-MM`. It is made here and sent as it is, a link
  to the storage cannot do that.
  """
  def show(conn, %{"month" => param}) do
    month =
      case Statement.parse_month(param) do
        {:ok, month} -> month
        :error -> raise Plug.BadRequestError, "the month is not YYYY-MM"
      end

    case Reports.month_zip(conn.assigns.current_scope, month) do
      {:ok, file_name, zip} ->
        send_download(conn, {:binary, zip}, filename: file_name, content_type: "application/zip")

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: ~p"/?month=#{param}")
    end
  end

  defp error_message(:no_statement), do: "There is no statement for this month yet."

  defp error_message({:storage, key, reason}) do
    Logger.error("Could not read #{key} for a month report: #{inspect(reason)}")
    "A PDF of this month could not be read, try again."
  end
end
