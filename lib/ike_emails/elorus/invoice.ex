defmodule IkeEmails.Elorus.Invoice do
  @moduledoc """
  An invoice issued in Elorus, as the API returns it. Only what reconciliation
  needs is parsed.

  Amounts are `Decimal`s in `:currency_code`, positive for an invoice.
  """

  defstruct [
    :id,
    :status,
    :representation,
    :number,
    :sequence_flat,
    :date,
    :client_name,
    :client_vat_number,
    :currency_code,
    :total,
    :payable,
    :permalink
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
      representation: data["representation"],
      number: blank_to_nil(data["number"]),
      sequence_flat: blank_to_nil(data["sequence_flat"]),
      date: date(data["date"]),
      client_name: data["client_display_name"],
      client_vat_number: blank_to_nil(data["client_vat_number"]),
      currency_code: data["currency_code"],
      total: decimal(data["total"]),
      payable: decimal(data["payable"]),
      permalink: data["permalink"] |> blank_to_nil() |> https_url()
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # The API gives the public link without a scheme, as "//host/path/"
  defp https_url("//" <> _ = url), do: "https:" <> url
  defp https_url(url), do: url

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
