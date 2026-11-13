defmodule IkeEmails.Storage.S3Test do
  # Talks to the local S3 server: docker compose up -d && mix test --include s3
  use ExUnit.Case, async: false

  @moduletag :s3

  alias IkeEmails.Storage.S3

  @config [
    bucket: "ike-emails-test",
    region: "us-east-1",
    endpoint_url: "http://127.0.0.1:8333",
    access_key_id: "ike-emails-dev",
    secret_access_key: "ike-emails-dev-secret"
  ]

  setup do
    previous = Application.fetch_env!(:ike_emails, S3)
    Application.put_env(:ike_emails, S3, @config)
    on_exit(fn -> Application.put_env(:ike_emails, S3, previous) end)

    assert :ok = S3.ensure_bucket()
    :ok
  end

  test "ensure_bucket/0 can be run again" do
    assert :ok = S3.ensure_bucket()
  end

  test "stores an object, serves it through a presigned URL and deletes it" do
    key = "invoices/test-#{System.unique_integer([:positive])}.pdf"
    body = "%PDF-1.4 stored in s3"

    assert :ok = S3.put(key, body, "application/pdf")

    response = Req.get!(S3.presigned_url(key, 60), retry: false)
    assert response.status == 200
    assert response.body == body
    assert response.headers["content-type"] == ["application/pdf"]

    assert :ok = S3.delete(key)
    assert Req.get!(S3.presigned_url(key, 60), retry: false).status == 404

    # Deleting what is gone is fine
    assert :ok = S3.delete(key)
  end

  test "fetches the bytes of an object, and reports one that is missing" do
    key = "invoices/test-#{System.unique_integer([:positive])}.pdf"
    body = "%PDF-1.4 fetched from s3"

    assert :ok = S3.put(key, body, "application/pdf")
    assert {:ok, ^body} = S3.fetch(key)

    assert :ok = S3.delete(key)
    assert {:error, {:unexpected_status, 404, _body}} = S3.fetch(key)
  end

  test "reports a refusal of the credentials" do
    Application.put_env(:ike_emails, S3, Keyword.put(@config, :secret_access_key, "wrong"))

    assert {:error, {:unexpected_status, 403, _body}} =
             S3.put("invoices/nope.pdf", "x", "application/pdf")
  end
end
