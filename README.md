# IkeEmails

## Local development

The invoice PDFs are stored in S3. Locally that is a SeaweedFS container
(S3 on `127.0.0.1:8333`, credentials in `dev/seaweedfs-s3.json`):

* Run `docker compose up -d` to start the local S3 server
* Run `mix setup` to install and setup dependencies; it also creates the bucket
  (`mix storage.setup` does only that)
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser. Log in
first: `mix setup` makes the user `dev@example.com` with the password
`dev-password-123` in development.

* `/` is the monthly reconciliation: the transactions of a month, each with its
  invoices. A transaction gets an invoice by uploading its PDF or attaching one
  that exists, or is marked "no invoice needed" with a reason (tax, dividends, ...).
* `/invoices` lists every invoice, and uploads one before its payment is known.
* `/settings` is where you say who you are (the name and VAT number of your business)
  and set up Elorus (your organization and your API key, see below).

Everything belongs to a user: each user sees only their own transactions, invoices and
settings.

`mix test` needs no S3 server; `mix test --include s3` also tests the S3 adapter
against the local one.

The invoices for income are issued in [Elorus](https://www.elorus.com). To read them
through its [API](https://developer.elorus.com) (`IkeEmails.Elorus`), each user sets up
their own account on `/settings`: the id of their organization (which every invoice of
the API carries as its `organization`) and their API key (found under "User Profile" in
Elorus), and "Use the Elorus demo environment" to work on a demo organization only.
Without a key the integration is off for that user. There are no environment variables
for it: users can work on different organizations.

The API key is kept sealed (`IkeEmails.Settings.SealedToken`): encrypted with a key made
from both the server key `SETTINGS_ENCRYPTION_KEY` and the login password of the user,
so a copy of the database is useless without the server key, and the server key is not
enough without the password. The password is asked when the key is saved, and again the
first time Elorus is used. That unlocks the key, which then lives only in memory, in a
process of its own for the user (`IkeEmails.Elorus.Connection`), until it has not been
used for 15 minutes, the user logs out or the server restarts. It is never in the
database in the clear, the session, the page or the logs. Unlocking is for the user and
not for the session: someone with a stolen session can use Elorus during that time
without the password.

With it, the panel to add an invoice to a transaction that is money in has a
section "Invoices in Elorus": a button asks Elorus for the invoices of the month
shown, the ones for the amount of the transaction first, and "Attach" downloads
the PDF and stores it as an invoice of the transaction. You are the issuer of
such an invoice, so set the name of your business (and its VAT number) on `/settings` to
say who you are; the client of the Elorus invoice becomes its receiver. Elorus allows 60
requests a minute and 1000 a day per user.

In development and in the tests the server key is a fixed one, in `config/dev.exs` and
`config/test.exs`: it is no secret, so do not put a real API key in a database that
others can read.

After a PDF is uploaded, "Extract with AI" reads it with a language model and fills
in the form (`IkeEmails.InvoiceExtractor`); you review the values and save. It is
not tied to a vendor: set `AI_MODEL` to a provider and a model, such as
`anthropic:claude-sonnet-5-5` or `openai:gpt-5`, and the API key of that provider in
its own variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, ...). The
work is done by [ReqLLM](https://hex.pm/packages/req_llm), which lists the providers
and the models. The model must accept PDFs. Switching provider is a change of
`AI_MODEL` and the key. The PDF is sent to the provider you choose, only when the
button is clicked. It is also told the business of the user, from `/settings`, to tell
the invoices they issued from those they received. Without `AI_MODEL` the feature is off.

In production the PDFs go to S3 or a compatible server, configured with the
environment variables `S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
and `AWS_REGION` (and `AWS_ENDPOINT_URL_S3` for a server that is not AWS).

The settings on `/settings` are not shared: every user has their own business, Elorus
organization and API key. `AI_MODEL`, the API key of its provider and the rest of the
environment are for the whole server.

The errors are reported to [Sentry](https://sentry.io) when `SENTRY_DSN` is set (the DSN
is in the settings of the project, use an EU project for the data to stay in the EU).
Without it nothing is sent. What is reported is the exception, the request without its
body and cookies, and the id of the user, never an email or an IP address. The release
is the commit that Kamal deployed.

Every call to Elorus and to the language model is also traced (`IkeEmails.Tracing`).
A trace of Elorus holds the method, the template of the path (never an invoice id), the
status and the time. A trace of the model (`gen_ai.chat`, shown by Sentry under
Explore, Agents) holds the provider, the model, the tokens, why it stopped and the size
of the PDF. Neither holds a header, a body, the prompt, the PDF or what was read from
it. Sentry does not scrub traces, so a new attribute has to be safe to send.

## Users

There is no sign-up page: users are created from the command line, with a password of
at least 12 characters.

    mix user.create me@example.com 'a long password'

In production, where there is no Mix, use the release (on Fly:
`fly ssh console -C "/app/bin/ike_emails eval '...'"`):

    bin/ike_emails eval 'IkeEmails.Release.create_user("me@example.com", "a long password")'

There is no password reset yet. Do not delete a user to start over: their transactions,
invoices and settings (the sealed Elorus key too) go with them.

The Elorus API key of a user is sealed with their password, so the day passwords can be
changed, a change must seal the key again (`IkeEmails.Settings.reseal_elorus_token/3`),
and a reset, where the old password is not known, must remove it
(`IkeEmails.Settings.clear_elorus_token/1`). The user then enters the key again.

## Deploying

The app runs on one server, deployed with [Kamal](https://kamal-deploy.org)
(`config/deploy.yml`). Every push to `main` runs the tests and, when they pass, the
GitHub Action `.github/workflows/deploy.yml` builds the image on the runner, pushes it to
`ghcr.io/tdgs/ike-emails` and rolls it out. Migrations run when the container starts, and
if one fails the previous version keeps running. To deploy without a push:

    gh workflow run deploy.yml --ref main

`make deploy` deploys from this machine instead, building the image on the server. To go
back to an older version, run `kamal rollback <version>` through
`op run --environment p3mdfiiyqkk6lf75sahcxlv6l4 --`.

The Action needs, once:

* a `production` environment on the repository (only the `main` branch may use it), with
  the secrets of `.kamal/secrets` and the secret `DEPLOY_SSH_KEY`, which `make sync-secrets`
  copies from 1Password: the first from the Environment `ike-emails-prod`, the second from
  the SSH Key item "ike-emails GitHub Actions deploy key" in the Employee vault, whose
  public key is in `~/.ssh/authorized_keys` of `deploy` on the server. It also holds the
  variable `SSH_KNOWN_HOSTS` (the output of `ssh-keyscan -t ed25519 <server>` without the
  comment line, checked against the real host key);
* write access of this repository to the package `ike-emails` (the package settings,
  "Manage Actions access"), or the push to ghcr.io fails with a 403.

`SETTINGS_ENCRYPTION_KEY` is one of those secrets, and the container does not start
without it: it must be 32 random bytes in base64, which

    openssl rand -base64 32

makes. Put it in the Environment `ike-emails-prod` and run `make sync-secrets` before
merging, as a merge to `main` deploys. It seals the Elorus API keys that are in the
database, so keep it with the other secrets and do not derive it from `SECRET_KEY_BASE`,
which is changed to revoke the API tokens. If it is changed or lost nothing else is lost: the users
enter their Elorus API keys again on `/settings`, as the old ones cannot be opened. There
is no rotation without that, since it would take each user's password.

The keys that are unlocked are in the memory of the server only, so every deploy and
restart locks them: the first use of Elorus after one asks for the password again.
`config/deploy.yml` sets `ERL_CRASH_DUMP_BYTES=0`, as a crash dump of the VM would hold
the keys that are unlocked.

The database is backed up every night to R2, see `deploy/backup/backup.sh`. The backup
holds the sealed API keys, and a restore needs the age key of the backup, the
`SETTINGS_ENCRYPTION_KEY` of the app that made it, and the password of each user to open
them. Without the key the restored app works, but Elorus says that the key cannot be
unlocked and the user sets it again. Removing an API key on `/settings` deletes it from
the database but not from the backups, which are kept for 30 days: revoke it in Elorus
to be sure, as after any leak of the server key.

The Elorus and business settings used to be the environment variables `ELORUS_API_TOKEN`,
`ELORUS_ORGANIZATION_ID`, `ELORUS_DEMO`, `BUSINESS_NAME` and `BUSINESS_VAT`, which are not
read any more. After deploying, each user enters theirs on `/settings` and unlocks Elorus once.
Then delete the old secrets from the Environment and from GitHub, and revoke the old
Elorus API key and issue a new one, as it was in the GitHub secrets and the container
environment.

## API

The bank crawler logs in as a user, and pushes that user's bank transactions. It trades
the email and password for a token:

    POST /api/auth/token
    Content-Type: application/json

    {"email": "me@example.com", "password": "a long password"}

* `200` `{"data": {"token": "...", "token_type": "Bearer", "expires_in": 86400}}`
* `401` the email or the password is wrong, or missing.

The token is good for 24 hours (`expires_in`, in seconds), after which the crawler asks
for another. It is signed with the `SECRET_KEY_BASE`, so changing that revokes every
token.

It pushes the bank transactions with the token, one per request:

    POST /api/transactions
    Authorization: Bearer <token>
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
* `401` missing, wrong or expired token.

The transaction is stored for the user of the token. Two users can have the same
`(transaction_id, amount, description)`.

It also sends the PDF of the bank statement of each month, with the same token:

    PUT /api/statements/2026-10
    Authorization: Bearer <token>
    Content-Type: multipart/form-data

    file=@statement.pdf

The month in the path is `YYYY-MM`. A month has one statement, so sending it again is
safe:

* `201` the statement of the month was stored.
* `200` the month had a statement already. A different PDF replaced it, and the old
  one is deleted; the same PDF changed nothing. The stored statement is returned.
* `422` the month is not `YYYY-MM`, the `file` is missing, or it is not a PDF:
  `{"errors": {"month": ["is invalid"]}}`.
* `413` the PDF is too large. The request body is limited to 8 MB.
* `503` the PDF could not be stored, try again.
* `401` missing, wrong or expired token.

The response is `{"data": {"id", "month": "2026-10", "file_name", "file_size",
"file_sha256", "inserted_at", "updated_at"}}`.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
