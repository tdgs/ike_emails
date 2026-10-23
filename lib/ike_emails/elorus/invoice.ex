defmodule IkeEmails.Elorus.Invoice do
  @moduledoc """
  An invoice issued in Elorus, as the API returns it. Only what reconciliation
  needs is parsed; `:raw` keeps the whole response (the line items of a single
  invoice, for example).

  Amounts are `Decimal`s in `:currency_code`, positive for an invoice.
  """

  defstruct [
    :id,
    :status,
    :draft,
    :representation,
    :number,
    :sequence_flat,
    :date,
    :due_date,
    :client_id,
    :client_name,
    :client_vat_number,
    :currency_code,
    :net,
    :total,
    :payable,
    :paid,
    :permalink,
    :raw
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds an invoice from a decoded API response. A field the API leaves out, or
  sends in a form that cannot be parsed, is `nil`.
  """
  def from_api(%{} = data) do
    %__MODULE__{
      id: data["id"],
      status: data["status"],
      draft: data["draft"],
      representation: data["representation"],
      number: blank_to_nil(data["number"]),
      sequence_flat: blank_to_nil(data["sequence_flat"]),
      date: date(data["date"]),
      due_date: date(data["due_date"]),
      client_id: data["client"],
      client_name: data["client_display_name"],
      client_vat_number: blank_to_nil(data["client_vat_number"]),
      currency_code: data["currency_code"],
      net: decimal(data["net"]),
      total: decimal(data["total"]),
      payable: decimal(data["payable"]),
      paid: decimal(data["paid"]),
      permalink: blank_to_nil(data["permalink"]),
      raw: data
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp date(_value), do: nil

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp decimal(_value), do: nil
end
