defmodule IkeEmails.Money do
  @moduledoc """
  Amounts as integer cents, and their text forms: typed in as `12,50`,
  `1.234,56` or `1234.56`, shown as `1.234,56 €`.
  """

  @doc """
  Parses an unsigned amount into cents.

  A single `,` or `.` followed by one or two digits is the decimal separator,
  otherwise the separators group thousands.

      iex> IkeEmails.Money.parse_cents("1.234,56")
      {:ok, 123456}
      iex> IkeEmails.Money.parse_cents("12.5")
      {:ok, 1250}
      iex> IkeEmails.Money.parse_cents("1.234")
      {:ok, 123400}
      iex> IkeEmails.Money.parse_cents("twelve")
      :error
  """
  def parse_cents(input) when is_binary(input) do
    cleaned = String.replace(input, ~r/[\s€]/u, "")

    with [_, whole, separator, fraction] <-
           Regex.run(~r/^(\d[\d.,]*?)(?:([.,])(\d{1,2}))?$/, cleaned) |> pad_match(),
         {:ok, euros} <- parse_whole(whole, separator) do
      {:ok, euros * 100 + fraction_cents(fraction)}
    else
      _ -> :error
    end
  end

  def parse_cents(_input), do: :error

  # Regex.run drops trailing groups that did not match
  defp pad_match([_, _] = match), do: match ++ ["", ""]
  defp pad_match([_, _, _] = match), do: match ++ [""]
  defp pad_match(match), do: match

  defp parse_whole(whole, separator) do
    cond do
      whole =~ ~r/^\d+$/ -> {:ok, String.to_integer(whole)}
      # Grouped thousands, in one notation that is not the decimal separator
      whole =~ ~r/^\d{1,3}(\.\d{3})+$/ and separator != "." -> {:ok, ungroup(whole)}
      whole =~ ~r/^\d{1,3}(,\d{3})+$/ and separator != "," -> {:ok, ungroup(whole)}
      true -> :error
    end
  end

  defp ungroup(whole), do: whole |> String.replace(~r/[.,]/, "") |> String.to_integer()

  defp fraction_cents(""), do: 0
  defp fraction_cents(<<_>> = fraction), do: String.to_integer(fraction) * 10
  defp fraction_cents(fraction), do: String.to_integer(fraction)

  @doc """
  Cents of a `Decimal` amount, keeping its sign.
  """
  def cents_from_decimal(%Decimal{} = amount) do
    amount |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
  end

  @doc """
  The amount typed back into a form, `12,50`.
  """
  def format_input(cents) when is_integer(cents), do: group(cents, "")

  @doc """
  The amount for display: `1.234,56 €`, `-9,00 €`, or with the currency code
  for any other currency, `20,00 USD`.
  """
  def format(cents, currency \\ "EUR") when is_integer(cents) do
    group(cents, " " <> symbol(currency))
  end

  defp symbol("EUR"), do: "€"
  defp symbol(currency), do: currency

  defp group(cents, suffix) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)
    euros = cents |> div(100) |> Integer.to_string() |> group_thousands()
    fraction = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{sign}#{euros},#{fraction}#{suffix}"
  end

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
    |> String.reverse()
  end
end
