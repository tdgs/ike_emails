defmodule IkeEmails.InvoiceExtractor do
  @moduledoc """
  Reads the facts of an invoice off its PDF with a language model, to fill in
  the invoice form.

  The model is optional, and it is not tied to a vendor: `AI_MODEL` names the
  provider and the model, such as `"anthropic:claude-sonnet-5-5"`, and the
  work is done by the configured `IkeEmails.InvoiceExtractor.Client`. Without a
  model, `configured?/0` is false and nothing is ever sent anywhere.

  What a model answers is only a suggestion, so every field is checked and a
  field that does not make sense is left out.
  """

  alias IkeEmails.Money

  @fields [
    amount: "The total to pay, VAT included, as a plain number such as 1234.50.",
    currency: "The three letter code of the currency, such as EUR.",
    date: "The date of the invoice, as YYYY-MM-DD.",
    issuer_name: "The name of the company that issued the invoice.",
    issuer_vat: "The VAT number of the issuer, as printed.",
    number: "The number of the invoice.",
    receiver_name: "The name of the customer. Only when the business issued the invoice.",
    receiver_vat: "The VAT number of the customer. Only when the business issued the invoice."
  ]

  @doc """
  Whether a model is set up.
  """
  def configured?, do: present?(config()[:model])

  @doc """
  The form params found in the PDF, with string keys, and only for the fields
  that were found: `amount_input`, `currency`, `date`, `issuer_name`,
  `issuer_vat`, `number`, `receiver_name` and `receiver_vat`.

  `:hints` are what is already known, from the bank transaction: a map of
  `:amount_input`, `:currency` and `:date`. `:business` is who the user is, as
  `IkeEmails.Settings.business/1` gives it (`%{name: name, vat: vat}`, or `nil`),
  so that the model can tell an invoice that the business issued from one it got.

  Returns `{:ok, params}`, or `{:error, reason}`: `:not_configured`,
  `:missing_key`, `:unauthorized`, `:rate_limited`, `:timeout`,
  `:invalid_response` or `{:failed, message}`.
  """
  def extract(pdf, opts \\ []) when is_binary(pdf) do
    config = config()

    if configured?() do
      prompt = prompt(Keyword.get(opts, :hints, %{}), Keyword.get(opts, :business))

      with {:ok, found} <- config[:client].generate(pdf, prompt, @fields, config[:model]) do
        {:ok, params(found)}
      end
    else
      {:error, :not_configured}
    end
  end

  @doc false
  def prompt(hints, business) do
    """
    This is an invoice. Read these facts off it: #{field_names()}.

    #{business(business)}

    Answer null for a fact that the invoice does not show. Do not guess.#{hints(hints)}
    """
    |> String.trim()
  end

  defp field_names, do: Enum.map_join(@fields, ", ", fn {name, _} -> to_string(name) end)

  defp business(%{name: name} = business) when is_binary(name) and name != "" do
    vat = if present?(business[:vat]), do: ", VAT number #{business.vat}", else: ""

    "The business that keeps these invoices is #{name}#{vat}. When it is the issuer, " <>
      "the invoice is one it issued to a customer, so read the customer as the " <>
      "receiver. Otherwise leave the receiver null."
  end

  defp business(_none) do
    "Leave the receiver null unless the invoice was clearly issued to a customer " <>
      "by the business that keeps it."
  end

  defp hints(hints) do
    known =
      [
        {"amount", hints[:amount_input]},
        {"currency", hints[:currency]},
        {"date", hints[:date]}
      ]
      |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
      |> Enum.map_join(", ", fn {name, value} -> "#{name} #{value}" end)

    if known == "" do
      ""
    else
      "\n\nThe bank shows a payment with #{known}. Use it only to choose between " <>
        "values that the invoice shows, never as a value of its own."
    end
  end

  defp params(found) do
    %{
      "amount_input" => amount(found["amount"]),
      "currency" => currency(found["currency"]),
      "date" => date(found["date"]),
      "issuer_name" => text(found["issuer_name"]),
      "issuer_vat" => text(found["issuer_vat"]),
      "number" => text(found["number"]),
      "receiver_name" => text(found["receiver_name"]),
      "receiver_vat" => text(found["receiver_vat"])
    }
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp amount(value) when is_binary(value) do
    case Money.parse_cents(value) do
      {:ok, cents} when cents > 0 -> Money.format_input(cents)
      _ -> nil
    end
  end

  defp amount(_value), do: nil

  defp currency(value) when is_binary(value) do
    code = value |> String.trim() |> String.upcase()
    if code =~ ~r/\A[A-Z]{3}\z/, do: code
  end

  defp currency(_value), do: nil

  defp date(value) when is_binary(value) do
    case value |> String.trim() |> Date.from_iso8601() do
      {:ok, date} -> Date.to_iso8601(date)
      {:error, _reason} -> nil
    end
  end

  defp date(_value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value), do: nil

  defp present?(value), do: is_binary(value) and value != ""

  defp config, do: Application.fetch_env!(:ike_emails, __MODULE__)
end
