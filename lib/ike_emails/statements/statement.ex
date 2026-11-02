defmodule IkeEmails.Statements.Statement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "statements" do
    # The first day of the month the statement is for
    field :month, :date

    field :file_key, :string
    field :file_name, :string
    field :file_size, :integer
    field :file_sha256, :string

    belongs_to :user, IkeEmails.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset of the statement of a month, with the facts of its stored PDF. The
  month is typed `YYYY-MM`.
  """
  def changeset(statement, month, file) do
    statement
    |> change(Map.take(file, [:file_key, :file_name, :file_size, :file_sha256]))
    |> put_month(month)
    |> unique_constraint([:user_id, :month],
      name: :statements_user_id_month_index,
      message: "has a statement already"
    )
  end

  @doc """
  The first day of the month typed `YYYY-MM`, or `:error`.
  """
  def parse_month(month) when is_binary(month) do
    with [_, year, month] <- Regex.run(~r/\A(\d{4})-(\d{2})\z/, month),
         {:ok, date} <- Date.new(String.to_integer(year), String.to_integer(month), 1) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  def parse_month(_month), do: :error

  defp put_month(changeset, month) do
    case parse_month(month) do
      {:ok, date} -> put_change(changeset, :month, date)
      :error -> add_error(changeset, :month, "is invalid")
    end
  end
end
