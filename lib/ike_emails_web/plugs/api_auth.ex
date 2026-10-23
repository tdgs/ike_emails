defmodule IkeEmailsWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates the external services that push data to the API with a static
  bearer token, `:bank_api_token`. Without a configured token every request is
  rejected.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with token when is_binary(token) and token != "" <-
           Application.get_env(:ike_emails, :bank_api_token),
         ["Bearer " <> given] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(given, token) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{errors: %{detail: "Unauthorized"}})
    |> halt()
  end
end
