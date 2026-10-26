# IkeEmails

## Local development

The invoice PDFs are stored in S3. Locally that is a SeaweedFS container
(S3 on `127.0.0.1:8333`, credentials in `dev/seaweedfs-s3.json`):

* Run `docker compose up -d` to start the local S3 server
* Run `mix setup` to install and setup dependencies; it also creates the bucket
  (`mix storage.setup` does only that)
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser:

* `/` is the monthly reconciliation: the transactions of a month, each with its
  invoices. A transaction gets an invoice by uploading its PDF or attaching one
  that exists, or is marked "no invoice needed" with a reason (tax, dividends, ...).
* `/invoices` lists every invoice, and uploads one before its payment is known.

`mix test` needs no S3 server; `mix test --include s3` also tests the S3 adapter
against the local one.

The invoices for income are issued in [Elorus](https://www.elorus.com). To read them
through its [API](https://developer.elorus.com) (`IkeEmails.Elorus`), set
`ELORUS_API_TOKEN` (the API key, found under "User Profile" in Elorus) and
`ELORUS_ORGANIZATION_ID` (the id of your organization, which every invoice of the
API carries as its `organization`). Add `ELORUS_DEMO=true` to work on a demo
organization only. Without a token the integration is off.

With it, the panel to add an invoice to a transaction that is money in has a
section "Invoices in Elorus": a button asks Elorus for the invoices of the month
shown, the ones for the amount of the transaction first, and "Attach" downloads
the PDF and stores it as an invoice of the transaction. You are the issuer of
such an invoice, so set `BUSINESS_NAME` (and `BUSINESS_VAT`) to say who you are;
the client of the Elorus invoice becomes its receiver. Elorus allows 60 requests a
minute and 1000 a day per user.

After a PDF is uploaded, "Extract with AI" reads it with a language model and fills
in the form (`IkeEmails.InvoiceExtractor`); you review the values and save. It is
not tied to a vendor: set `AI_MODEL` to a provider and a model, such as
`anthropic:claude-sonnet-5-5` or `openai:gpt-5`, and the API key of that provider in
its own variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, ...). The
work is done by [ReqLLM](https://hex.pm/packages/req_llm), which lists the providers
and the models. The model must accept PDFs. Switching provider is a change of
`AI_MODEL` and the key. The PDF is sent to the provider you choose, only when the
button is clicked. Without `AI_MODEL` the feature is off.

In production the PDFs go to S3 or a compatible server, configured with the
environment variables `S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
and `AWS_REGION` (and `AWS_ENDPOINT_URL_S3` for a server that is not AWS).
There is no login yet: do not expose the app before adding one.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## API

The bank crawler pushes bank transactions, one per request:

    POST /api/transactions
    Authorization: Bearer <BANK_API_TOKEN>
    Content-Type: application/json

    {"date": "2026-10-19", "value_date": "2026-10-17", "description": "ANTHROPIC* CLAUDE SU",
     "branch": "99", "transaction_id": "202610190993537650", "amount": "-90.00",
     "conversion_details": null, "sender_details": null, "additional_information": null}

The fields are the columns of the crawler's `transactions.csv`. `amount` is a
signed decimal string (negative is money out), dates are `YYYY-MM-DD`. The
last three fields are optional.

* `201` the transaction was stored.
* `200` the transaction was already stored; the stored one is returned. A
  transaction is told apart by `(transaction_id, amount, description)`, since
  the bank books a transfer and its fee under the same `transaction_id`. Pushing
  a statement again is therefore safe.
* `422` invalid fields: `{"errors": {"amount": ["is invalid"]}}`.
* `401` missing or wrong token.

The token is read from the `BANK_API_TOKEN` environment variable in production,
and is `dev-bank-api-token` in development.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
