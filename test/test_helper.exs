# Needs the local S3 server: docker compose up -d && mix test --include s3
# Needs a real Chrome (CHROME_PATH, or one on the PATH): mix test --include chrome
ExUnit.configure(exclude: [s3: true, chrome: true])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(IkeEmails.Repo, :manual)
IkeEmails.Storage.InMemory.start()
