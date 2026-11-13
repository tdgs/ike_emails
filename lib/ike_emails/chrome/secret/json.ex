defimpl Jason.Encoder, for: IkeEmails.Chrome.Secret do
  # The one place where the string leaves the struct: it is typed in as a JSON string
  def encode(secret, opts) do
    secret |> IkeEmails.Chrome.Secret.reveal() |> Jason.Encode.string(opts)
  end
end
