defmodule IkeEmails.Bank.Alpha.Script do
  @moduledoc """
  The JavaScript that a crawl runs in the pages of myAlpha, from `priv/bank`:

    * `:login` - `login.js`, for the login page: it finds the visible inputs, fills them
      in, tells how a login ended and logs out
    * `:statements` - `statements.js`, for the logged in app: it fetches the statements,
      the details of the transactions, the list of the monthly statements and their PDF
      through the app's own `$http`, so that the bank sees the requests it expects

  They are the files of the crawler written in Gleam, byte for byte (a test pins their
  sha256, so that they cannot change without anyone noticing). They are read when this
  module is compiled and kept in it, so that a release does not need the file at run
  time, and are compiled again when one of them changes.

  Each evaluates to an object of functions, and the driver calls one of them with an object
  of arguments. Nothing is ever put into the text of a script: a user name or a password
  goes in only as one of those arguments.
  """

  @doc """
  The text of the script, `:login` or `:statements`.
  """
  @spec source(:login | :statements) :: String.t()
  def source(name)

  for {name, file} <- [login: "login.js", statements: "statements.js"] do
    path = Path.expand("../../../../priv/bank/#{file}", __DIR__)
    @external_resource path
    @source File.read!(path)

    def source(unquote(name)), do: @source
  end
end
