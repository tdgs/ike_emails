# Golden fixtures of the Alpha bank parsers

Each file is a list of cases: an input, and what the **Gleam crawler** made of it
(`/Users/tdgs/projects/bank_crawler`, the code `IkeEmails.Bank.Alpha` was ported from).
`test/ike_emails/bank/alpha/golden_test.exs` feeds every input to the Elixir module and checks
that the result is the same, so the equivalence holds without Gleam installed. It matters because
`description`, `amount` and `transaction_id` of a row are the key by which a stored transaction is
found again: a difference would store it a second time.

The files are written one case per line, and are plain ASCII (every character outside it is a
`\uXXXX` escape), so that the invisible ones can be seen in a diff.

| File | Cases | Case |
| --- | --- | --- |
| `text_clean.json` | 422 | `{"input", "expected"}`: `Text.clean/1` |
| `amounts.json` | 249 | `{"amount", "sign", "expected"}`: the text of the JSON number and the sign letter of one line; `expected` is `{"amount": "-126.51"}`, or `{"error": "statements"}` when the line cannot be read |
| `rows.json` | 126 | `{"note", "statements", "details", "expected"}`: see below |
| `estatements.json` | 117 | `{"note", "body", "expected"}`: `EStatements.parse/1`, `latest/1`, `file_name/1`, `month/1` |
| `session_in_use.json` | 19 | `{"message", "expected"}`: `Login.session_in_use?/1` |

`rows.json`: `statements` is the text of the bank's statements response, and `details` the text of
the answer of the details call by transaction id (what `Statements.parse/1` and `Details.parse/1`
take). `expected` is either `{"error": "statements"}` or `{"error": "details"}`, the call that
fails, or the three things the Gleam crawler made: `statements` (each line as read, before any
cleaning, with its own `detail` or `null`), `details` (the parsed answers by id) and `rows` (the
nine columns of each row, in the order of the lines). Every date in it is a valid `d/M/yyyy`, so
`Rows.build/2` rejects no line (`rejected_ids` is `[]`).

`estatements.json`: `expected` is `{"error": "unexpected_response"}`, or `estatements` (the issued
ones, each with its `file_name` and its `month`) and `latest`, the position in that list of the one
`latest/1` picks (`null` for an empty list). The Gleam crawler gets the month from a file name
(`estatement_month`) and has none for a month that is not 01 to 12, so `month` is `null` there;
the test applies the same check to the month of the Elixir module, which has only the one of a
statement.

The Gleam crawler writes an empty text where the bank has nothing; the Elixir rows have `nil` for
`branch`, `conversion_details`, `sender_details` and `additional_information` (the Ecto cast of a
row turns an empty text into `nil` too). The test compares a `nil` in those four as an empty text,
and nothing else is normalised.

## Synthetic data only

Nothing here was read from a bank, a statement or any file of the owner. The merchants, senders,
notes and ids are invented (`ZEPHYR MARKET`, `MARIGOLD TRADING LTD`, `TIMBER KETTLE`, ...), some
with their Latin letters swapped for the Greek capitals that look the same, as the bank does. The
amounts and dates are made up. The JSON bodies have the shape of the bank's responses, as the
Elixir tests describe it.

## How they were made

The inputs were built by a script with fixed seeds, and **the outputs are what the real Gleam
functions returned for them**. Nothing in a fixture was worked out by hand or by the Elixir code.

* Gleam 1.19.2 on Erlang/OTP 28, with `gleam_stdlib` 1.0.5 and `gleam_json` 3.1.0, the versions in
  the `manifest.toml` of `bank_crawler`.
* A scratch Gleam project held a verbatim copy of the pure functions of
  `bank_crawler/src/alpha_bank.gleam` and `src/transactions_csv.gleam` (the revision `0b5a87a`; the
  two files are as committed, sha-256 `d9863f803813` and `6842c3511767`): `is_session_in_use`, the
  statement, estatement and detail decoders, `parse_statements`, `parse_details`,
  `parse_estatements`, `latest_estatement`, `estatement_file_name`, `estatement_month`, `rows` and
  what it uses (`clean`, `iso_date`, `amount`). Only the visibility of those three, the module
  prefix of `Detail` and the variants of the error type that these functions never return differ.
  It was built with `gleam build`, and its BEAM files were called from a script run by
  `MIX_ENV=test mix run` (Elixir 1.19.4, Jason 1.4.5, Decimal 3.2.0).
* The same script ran the Elixir modules on every input as well, and wrote a fixture only when
  the two agreed apart from the two differences below.
* Generated on 2026-11-04. Seeds of `:rand.seed(:exsss, {a, b, c})`: `text_clean.json`
  `{101, 102, 103}`, `amounts.json` `{201, 202, 203}`, `rows.json` `{301, 302, 303}`,
  `estatements.json` `{401, 402, 403}`. The script and the scratch project are not in the
  repository, and the files are not meant to be generated again unless the Gleam crawler changes.

What they cover:

* `text_clean.json`: every character of the trim set (U+0009 to U+000D, U+0020, U+0085, U+200E,
  U+200F, U+2028, U+2029) alone, at either end and in the middle; the ones that are **not**
  trimmed (U+00A0, U+1680, U+2000 to U+200A, U+202F, U+205F, U+3000, U+200B, U+FEFF); the 14 Greek
  capitals that look like a Latin letter, each beside a Latin letter and all together; every code
  point of the Greek block (U+0370 to U+03FF) in a word with a Latin letter and a look-alike;
  mixed words, digits, `*`, lower case Greek, final sigma, capitals without a look-alike (Sigma,
  Omega), accented capitals, polytonic letters, combining marks, emoji; and about 95 random strings
  of 1 to 9 characters from an alphabet of these.
* `amounts.json`: integers, one and two decimals (with the usual float traps such as 4.35 and
  1.15), negatives, zero in several spellings including `-0`, exponent notation, values up to 1e11,
  amounts with more than two decimals that are not a tie (`18.014`, `0.0049`), the four sign
  letters (Greek Chi and Pi, Latin X and P), and numbers and signs that are not valid.
* `rows.json`: a line with its own details, with none, with the details of the call, with an empty
  list or `null`, with an empty detail that must win over the call's, lines that share a
  `TransactionUN`, several entries joined by `" | "`, blank and `null` texts, a branch with
  spaces, ids with leading zeros, escaped Unicode, the failures of the decoders, and 52 random ones.
* `estatements.json`: issued and not issued months, tied end dates, year changes, dates that are
  not `yyyy-mm-dd` (other digits, a newline, a path, a combining mark, month 00 and 13) and
  entries that lack a field or have one of another type.

## The two differences left out

The Elixir modules are not the same as the Gleam crawler in two documented places, and the cases
that show them are **not** in the fixtures:

1. **An amount with more than two decimals that is a tie**, such as `1.005` or `1.035`. The Gleam
   crawler rounds the float `value * 100`, and the float nearest to `1.005` is a little under it, so
   it gives `1.00`; `Rows` rounds the decimal as written, half away from zero, and gives `1.01`.
   Of the 24 tie amounts tried with four signs, those that differ are `1.005`, `1.035` and `-1.005`;
   every exact tie is left out, whether it differs or not, so that no case depends on the binary
   value of a float. The bank writes two decimals, for which the two agree. Amounts above about
   1e13 are not in the fixtures either: floats lose the cents there.
2. **A leading space followed by a combining mark, a zero width joiner (U+200D) or a variation
   selector 16 (U+FE0F).** Gleam's `string.trim` works on graphemes, and the space and the mark are
   one grapheme that is not a space, so it keeps both; `Text.clean/1` trims by code point and takes
   the space off. Only the start of a text is affected: of 200,000 random strings, 455 had a start
   that the two trims read differently and all of them differed; no other string did, and no
   trailing space. The random strings of `text_clean.json` are the ones in which the grapheme
   trim and the code point trim give the same.

Nothing else differed, on the inputs of these files and on the random ones of the review of the
port.
