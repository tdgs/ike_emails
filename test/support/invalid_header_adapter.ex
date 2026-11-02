defmodule IkeEmails.InvalidHeaderAdapter do
  @moduledoc """
  A `Req` adapter that fails like Mint does when a header value is not allowed (a
  line break, for example): with the value in the message of the error. `Req.Test`
  never gets to Mint, so this is how the tests reach that error.

      Application.put_env(:ike_emails, IkeEmails.Elorus,
        req_options: [adapter: IkeEmails.InvalidHeaderAdapter])
  """

  def run(request) do
    [value] = Req.Request.get_header(request, "authorization")

    {request,
     %Req.HTTPError{
       protocol: :http1,
       reason: {:invalid_header_value, "authorization", value}
     }}
  end
end
