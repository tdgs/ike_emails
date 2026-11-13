defmodule IkeEmails.Bank.Alpha.Fields do
  @moduledoc """
  Readers for the fields of the JSON that the bank sends, for the parsers of
  `IkeEmails.Bank.Alpha`. Each takes the decoded object and the name of a field, and
  returns `{:ok, value}` or `:error`; none of them raises, whatever the bank sent.

  They keep the strictness of the crawler this was ported from: a field that is
  required is an error when it is missing, when it is `null` and when it has another
  type, and a number is an integer or a `Decimal` (the body is decoded with
  `Jason.decode(floats: :decimals)`, so that an amount is never a float).

  The sign of an amount is `:debit` for the Greek capital Chi (U+03A7) or the Latin `X`,
  and `:credit` for the Greek capital Pi (U+03A0) or the Latin `P`: the bank sends the
  Greek letters, and the Latin look-alikes are accepted as well. Any other sign is
  an error.
  """

  @type sign :: :debit | :credit

  @doc "A required string."
  def string(object, name) when is_map(object) do
    case object do
      %{^name => value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  def string(_object, _name), do: :error

  @doc "A string that may be missing or `null`, which is the same as an empty one."
  def text(object, name) when is_map(object) do
    case Map.get(object, name) do
      nil -> {:ok, ""}
      value when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  def text(_object, _name), do: :error

  @doc "A required list."
  def list(object, name) when is_map(object) do
    case object do
      %{^name => value} when is_list(value) -> {:ok, value}
      _ -> :error
    end
  end

  def list(_object, _name), do: :error

  @doc "A required number, as a `Decimal`."
  def number(object, name) when is_map(object) do
    case object do
      %{^name => value} -> to_decimal(value)
      _ -> :error
    end
  end

  def number(_object, _name), do: :error

  @doc "A number that may be missing or `null`, which gives `nil`."
  def optional_number(object, name) when is_map(object) do
    case Map.get(object, name) do
      nil -> {:ok, nil}
      value -> to_decimal(value)
    end
  end

  def optional_number(_object, _name), do: :error

  @doc "A required sign of an amount."
  def sign(object, name) do
    with {:ok, value} <- string(object, name), do: to_sign(value)
  end

  @doc "A sign of an amount that may be missing or `null`, which gives `nil`."
  def optional_sign(object, name) when is_map(object) do
    case Map.get(object, name) do
      nil -> {:ok, nil}
      value when is_binary(value) -> to_sign(value)
      _ -> :error
    end
  end

  def optional_sign(_object, _name), do: :error

  @doc """
  Maps `fun`, which returns `{:ok, value}` or `:error`, over `list`: `{:ok, values}` in the same
  order, or `:error` as soon as one is.
  """
  def all(list, fun) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, values} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp to_decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp to_decimal(%Decimal{coef: coef} = value) when is_integer(coef), do: {:ok, value}
  defp to_decimal(_value), do: :error

  defp to_sign("\u{03A7}"), do: {:ok, :debit}
  defp to_sign("X"), do: {:ok, :debit}
  defp to_sign("\u{03A0}"), do: {:ok, :credit}
  defp to_sign("P"), do: {:ok, :credit}
  defp to_sign(_value), do: :error
end
