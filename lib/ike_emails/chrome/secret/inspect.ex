defimpl Inspect, for: IkeEmails.Chrome.Secret do
  def inspect(_secret, _opts), do: "#Secret<redacted>"
end
