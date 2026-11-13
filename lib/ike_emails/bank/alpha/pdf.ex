defmodule IkeEmails.Bank.Alpha.Pdf do
  @moduledoc """
  Decodes the PDF of a monthly statement, which `priv/bank/statements.js` fetches
  (`fetchEStatement`) inside the page and hands over as its size in bytes and its content
  in base64.

  The page has checked that the content starts with `%PDF-`, ends with `%%EOF`, and has
  the size the bank announced. This checks again what costs next to nothing, since the
  file is kept as the statement of a month: the base64 must be valid, the bytes it
  decodes to must come to the size that was sent with them, and they must start with
  `%PDF-`. A cut-off or garbled transfer fails at least one of them.
  """

  @doc """
  The PDF as a binary, or `{:error, :invalid_pdf}` for anything that is not what the module
  describes.
  """
  @spec decode(%{bytes: non_neg_integer(), base64: String.t()}) ::
          {:ok, binary()} | {:error, :invalid_pdf}
  def decode(%{bytes: size, base64: content}) when is_integer(size) and is_binary(content) do
    with {:ok, pdf} <- Base.decode64(content),
         true <- byte_size(pdf) == size,
         <<"%PDF-", _rest::binary>> <- pdf do
      {:ok, pdf}
    else
      _ -> {:error, :invalid_pdf}
    end
  end

  def decode(_response), do: {:error, :invalid_pdf}
end
