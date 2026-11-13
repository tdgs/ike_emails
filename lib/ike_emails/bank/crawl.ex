defmodule IkeEmails.Bank.Crawl do
  @moduledoc """
  What a crawl read from the bank. It is not stored: `IkeEmails.Bank.Sync.crawl/2` only
  returns it, so that whoever runs it decides where it goes (the database, or the API of
  the app).

    * `rows` - the transactions, as the attributes that `IkeEmails.Banking.create_transaction/2`
      takes (see `IkeEmails.Bank.Alpha.Rows`). Rows whose details could not be read are not in
      it, they are in `skipped`, and lines whose date could not be read, in `rejected`
    * `statement` - the latest monthly statement as `%{month: "2026-10", file_name:
      "estatement-2026-10.pdf", pdf: binary}`, or `nil` when there is none or the bank stopped
      the crawl
    * `details_failed` - how many transactions had no valid details
    * `skipped` - the transaction ids that were left out because of that. A later crawl asks
      for their details again
    * `rejected` - the transaction ids of the lines that were left out because their date
      could not be read, once for each line. It is not the same as `skipped`, and
      `details_failed` does not count it: those lines are left out for good, and every later
      crawl leaves them out again, so whoever runs the crawl has to show a list that is not
      empty. A line that is in `skipped` is not in it, whatever its date, until a crawl has
      its details
    * `stopped` - `nil`, or the status (401 or 403) with which the bank refused a request
  """

  defstruct rows: [],
            statement: nil,
            details_failed: 0,
            skipped: [],
            rejected: [],
            stopped: nil

  @type row :: %{
          date: String.t(),
          value_date: String.t(),
          description: String.t(),
          branch: String.t() | nil,
          transaction_id: String.t(),
          amount: String.t(),
          conversion_details: String.t() | nil,
          sender_details: String.t() | nil,
          additional_information: String.t() | nil
        }

  @type t :: %__MODULE__{
          rows: [row()],
          statement: nil | %{month: String.t(), file_name: String.t(), pdf: binary()},
          details_failed: non_neg_integer(),
          skipped: [String.t()],
          rejected: [String.t()],
          stopped: nil | 401 | 403
        }

  @doc """
  Whether the bank let the crawl read everything it asked for. A crawl that is not complete
  has rows, but no statement. It says nothing of `skipped` or `rejected`.
  """
  def complete?(%__MODULE__{stopped: nil}), do: true
  def complete?(%__MODULE__{}), do: false
end
