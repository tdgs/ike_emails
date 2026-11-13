defmodule IkeEmails.Bank.Alpha.Detail do
  @moduledoc """
  What the bank says about a transaction beyond the statement line: the amount in the
  original currency, such as `20,00 USD`, who sent it and a note. Each is a string, empty
  when the bank has nothing. The texts are as the bank sent them; `IkeEmails.Bank.Alpha.Rows`
  cleans them.

  The bank lists the details of a transaction in a list of entries, in the statement
  itself and in the answer to the details call. `from_entries/1` makes one `Detail`
  of them. The list has one entry, but should it ever have several, their texts are
  joined with `" | "`, each field on its own. Only an empty text is left out of a join:
  a text of spaces is a text, and is joined as it is.
  """

  alias IkeEmails.Bank.Alpha.Fields

  defstruct conversion_details: "", sender_details: "", additional_information: ""

  @type t :: %__MODULE__{
          conversion_details: String.t(),
          sender_details: String.t(),
          additional_information: String.t()
        }

  @separator " | "

  @doc """
  The `Detail` of a list of entries as the bank sends them (decoded JSON objects), or
  `:error` when one is not an object or has a text that is not a string. A text that is
  missing or `null` is empty.
  """
  @spec from_entries([map()]) :: {:ok, t()} | :error
  def from_entries(entries) when is_list(entries) do
    with {:ok, entries} <- Fields.all(entries, &entry/1) do
      {:ok,
       %__MODULE__{
         conversion_details: joined(entries, :conversion_details),
         sender_details: joined(entries, :sender_details),
         additional_information: joined(entries, :additional_information)
       }}
    end
  end

  defp entry(object) do
    with {:ok, conversion_details} <- Fields.text(object, "ConversionDetails"),
         {:ok, sender_details} <- Fields.text(object, "SenderDetails"),
         {:ok, additional_information} <- Fields.text(object, "AdditionalInformation") do
      {:ok,
       %__MODULE__{
         conversion_details: conversion_details,
         sender_details: sender_details,
         additional_information: additional_information
       }}
    end
  end

  defp joined(entries, field) do
    entries
    |> Enum.map(&Map.fetch!(&1, field))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(@separator)
  end
end
