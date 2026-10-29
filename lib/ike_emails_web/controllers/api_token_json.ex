defmodule IkeEmailsWeb.ApiTokenJSON do
  def show(%{token: token, expires_in: expires_in}) do
    %{data: %{token: token, token_type: "Bearer", expires_in: expires_in}}
  end
end
