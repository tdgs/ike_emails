defmodule IkeEmailsWeb.PageController do
  use IkeEmailsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
