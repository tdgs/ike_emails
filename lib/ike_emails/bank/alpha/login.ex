defmodule IkeEmails.Bank.Alpha.Login do
  @moduledoc """
  What the login page of myAlpha says, as far as a crawl has to tell it apart.

  The bank allows one session at a time. When one is open, it ends that one and refuses
  the login in progress, with a message that says, in Greek, that the account is already
  in use, possibly from another computer, and asks to log in again. A crawl logs in
  again when it reads that, a few times, and does not when the message is any other: a
  user name or a password that the bank refused is not tried again.
  """

  # "is already in use": the text is compared as the bank writes it, with the accent on
  # the ι and on the η, each as one character
  @session_in_use "χρησιμοποιείται ήδη"

  @doc """
  Whether `message`, the error the login page shows, says that the account is already in
  use.
  """
  @spec session_in_use?(String.t()) :: boolean()
  def session_in_use?(message) when is_binary(message) do
    String.contains?(message, @session_in_use)
  end

  def session_in_use?(_message), do: false
end
