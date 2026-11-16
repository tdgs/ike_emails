defmodule IkeEmails.Terminal do
  @moduledoc """
  Reads a secret, such as a password, from the terminal without showing it: for
  `mix bank.probe`, `mix user.create` and `IkeEmails.Release.create_user/1`. A secret
  that is an argument of a command ends up in the history of the shell and in the
  output of Kamal; `:io.get_password/0` does not work where the node has no shell, as
  under `bin/ike_emails eval`.

  The echo is turned off with `stty`, and turned back on whatever happens. Without a
  terminal nothing is read.

  The line is read as UTF-8: `IO.gets/1` decodes by the locale of the node, and with
  `LANG` and `LC_ALL` unset or `C` it takes the bytes of "ä" for two Latin-1 characters
  and returns two others, which is still valid UTF-8, so nothing would notice and the
  password would be another one than the one typed. The encoding of the device is what
  is changed (`IO.binread/2` is not the way: in a UTF-8 locale it fails), and put back.
  """

  @type error :: :in_iex | :no_terminal | :not_text | :unreadable | :nothing_typed

  @doc """
  The line that was typed, without its end of line, or an error, which holds nothing of
  what was typed. See `message/1` for the errors.
  """
  @spec read_secret(String.t()) :: {:ok, String.t()} | {:error, error()}
  def read_secret(prompt) do
    with :ok <- check_shell(Code.ensure_loaded?(IEx) and IEx.started?()),
         0 <- stty("-echo") do
      encoding = io_encoding()

      line =
        try do
          :io.setopts(:standard_io, encoding: :unicode)
          IO.gets(prompt)
        after
          restore_io_encoding(encoding)
          stty("echo")
          IO.puts("")
        end

      typed(line)
    else
      {:error, _reason} = error -> error
      _stty_failed -> {:error, :no_terminal}
    end
  end

  @doc "What an error of `read_secret/1` means, for the person at the terminal."
  @spec message(error()) :: String.t()
  def message(:in_iex),
    do: "The password cannot be hidden inside iex, it would be shown. Run it from a plain shell."

  def message(:no_terminal), do: "This needs a terminal to ask for the password."
  def message(:not_text), do: "What was typed is not valid UTF-8 text."
  def message(:unreadable), do: "What was typed could not be read as text."
  def message(:nothing_typed), do: "Nothing was typed."

  @doc false
  # In IEx the terminal is not the one `stty` is given: the echo stays on, and the
  # password would be shown as it is typed
  def check_shell(false), do: :ok
  def check_shell(true), do: {:error, :in_iex}

  @doc false
  # What `IO.gets/1` returned, as the text that was typed. The spaces are kept, they can
  # be part of a password
  def typed(line) when is_binary(line) do
    cond do
      not String.valid?(line) -> {:error, :not_text}
      String.replace(line, ~r/\r?\n\z/, "") == "" -> {:error, :nothing_typed}
      true -> {:ok, String.replace(line, ~r/\r?\n\z/, "")}
    end
  end

  def typed({:error, _reason}), do: {:error, :unreadable}
  def typed(_eof), do: {:error, :nothing_typed}

  defp io_encoding do
    case :io.getopts(:standard_io) do
      options when is_list(options) -> Keyword.get(options, :encoding)
      _unsupported -> nil
    end
  end

  defp restore_io_encoding(nil), do: :ok
  defp restore_io_encoding(encoding), do: :io.setopts(:standard_io, encoding: encoding)

  # The terminal that the node was started from: the program has to be given its input and
  # its output as they are (`:nouse_stdio`). Run by `System.cmd/3` it gets pipes instead,
  # and a port does not give it a terminal of its own either, so `/dev/tty` cannot be
  # opened. The setting is one of two words, written in the code, and never from outside
  defp stty(setting) do
    case System.find_executable("stty") do
      nil ->
        1

      stty ->
        port = Port.open({:spawn_executable, stty}, [:nouse_stdio, :exit_status, args: [setting]])

        receive do
          {^port, {:exit_status, status}} -> status
        after
          :timer.seconds(5) -> 1
        end
    end
  end
end
