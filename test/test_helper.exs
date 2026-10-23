# Needs the local S3 server: docker compose up -d && mix test --include s3
ExUnit.configure(exclude: [s3: true])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(IkeEmails.Repo, :manual)
IkeEmails.Storage.InMemory.start()
