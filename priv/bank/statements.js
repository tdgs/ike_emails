// Runs in the logged in myAlpha Web page. Evaluates to an object of functions.
(() => {
  // The app's own $http adds the XSRF and session headers. Resolves to it once
  // AngularJS has started.
  const ready = async () => {
    let injector;
    for (let i = 0; i < 100 && !injector; i++) {
      injector = window.angular && angular.element(document.body).injector();
      if (!injector) await new Promise((resolve) => setTimeout(resolve, 200));
    }
    if (!injector) throw new Error("AngularJS did not start");
    return injector.get("$http");
  };

  // Makes `call()` and logs it as `what`, how long it took and how it ended.
  // A failure is thrown as an Error with the HTTP `status` of the bank's answer.
  const logged = async (what, call) => {
    // Shared by the calls, which each evaluate this file again.
    const number = (window.crawlerRequests = (window.crawlerRequests || 0) + 1);
    const started = performance.now();
    const took = () => Math.round(performance.now() - started) + " ms";
    // The Gleam side prints what is logged with this tag.
    console.log("[crawler]", "#" + number, "request", what);
    try {
      const response = await call();
      console.log("[crawler]", "#" + number, "done in", took());
      return response;
    } catch (rejection) {
      // $http rejects with the response, which says nothing when logged.
      const error =
        rejection instanceof Error
          ? rejection
          : new Error("HTTP " + rejection.status + ": " + String(JSON.stringify(rejection.data)).slice(0, 500));
      error.status = rejection.status;
      console.error("[crawler]", "#" + number, "failed in", took(), error.message);
      throw error;
    }
  };

  // Resolves to a `post(fields, endpoint)` that posts `fields` for the account to
  // `endpoint` of the bank's products service: the statements, by default.
  const connect = async (iban) => {
    const $http = await ready();
    return (fields, endpoint = "getAggregatedAccountStatements") => {
      const what = fields.GetSummary
        ? "statements " + fields.GetSummary.FromDate + " to " + fields.GetSummary.ToDate
        : fields.GetDetails
          ? "details of " + fields.GetDetails.UN
          : endpoint;
      return logged(what, () =>
        $http.post("/myAlphaWeb/business/api/products.svc/" + endpoint, {
          ProductCode: iban,
          ProductTypeID: 6,
          ...fields,
          ActivityDateTime: new Date().toISOString(),
          UniqueIdentifier: crypto.randomUUID(),
        }),
      );
    };
  };

  // The bytes as base64 text, in pieces: `String.fromCharCode` takes only so many
  // arguments at once.
  const base64 = (bytes) => {
    let text = "";
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(text);
  };

  const latin1 = (bytes) => String.fromCharCode(...bytes);

  // How long each of the parallel workers waits after a call to the details.
  const pause = 200;

  const day = 86400000;
  // Calendar days as UTC milliseconds, so that daylight saving cannot skew them.
  const format = (ms) => {
    const date = new Date(ms);
    return date.getUTCDate() + "/" + (date.getUTCMonth() + 1) + "/" + date.getUTCFullYear();
  };

  return {
    // The statements of the last `days` days, as the bank's JSON text: the first
    // response, with its `Statements` replaced by all of them. When the bank says
    // there are more records than fit in one response, the date range is split in
    // halves, recursively, instead of using its paging.
    //
    // Nothing tells how many records there are in all: `TotalRecords` is only
    // that of a page. So the result is checked against the balances instead: the
    // statements of every piece must add up to how much its balance moved, and
    // the balance where a piece ends must be where the next one starts.
    fetch: async ({ iban, days }) => {
      const post = await connect(iban);
      const range = (from, to) => post({ GetSummary: { FromDate: format(from), ToDate: format(to) } });

      // Signed, in cents, to add them up exactly. Debits are the Greek Χ.
      const cents = (amount, sign) => {
        if (sign === "Χ" || sign === "X") return -Math.round(amount * 100);
        if (sign === "Π" || sign === "P") return Math.round(amount * 100);
        throw new Error("unknown amount sign " + JSON.stringify(sign));
      };

      // A piece of the range that came back whole, checked against its balances.
      const piece = (from, to, response) => {
        const statements = response.Statements;
        const previous = [response.PreviousGrossBalance, response.PreviousGrossBalanceSign];
        const next = [response.NewGrossBalance, response.NewGrossBalanceSign];
        const known = [...previous, ...next].every((value) => value !== null && value !== undefined);
        const opening = known ? cents(...previous) : null;
        const closing = known ? cents(...next) : null;
        if (known) {
          const added = statements.reduce((sum, { Amount, AmountSign }) => sum + cents(Amount, AmountSign), 0);
          if (added !== closing - opening) {
            throw new Error(
              "the " + statements.length + " statements from " + format(from) + " to " + format(to) +
                " add up to " + added / 100 + " but the balance moved by " + (closing - opening) / 100,
            );
          }
        }
        return { statements, previous, next, opening, closing };
      };

      // Newest first, like the bank. `known` is an already fetched response.
      const fetchRange = async (from, to, known) => {
        const response = known || (await range(from, to));
        if (!response.HasMore) return piece(from, to, response);
        if (from === to) throw new Error("more than one page for the single day " + format(from));
        const middle = from + Math.floor((to - from) / day / 2) * day;
        const older = await fetchRange(from, middle);
        const newer = await fetchRange(middle + day, to);
        if (older.closing !== null && newer.opening !== null && older.closing !== newer.opening) {
          throw new Error(
            "the balance at the end of " + format(middle) + " is " + older.closing / 100 +
              " but at the start of " + format(middle + day) + " it is " + newer.opening / 100,
          );
        }
        return {
          statements: newer.statements.concat(older.statements),
          previous: older.previous,
          next: newer.next,
          opening: older.opening,
          closing: newer.closing,
        };
      };

      const now = new Date();
      const to = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
      const from = to - days * day;
      const first = await range(from, to);
      const all = await fetchRange(from, to, first);
      return JSON.stringify(
        {
          ...first,
          HasMore: false,
          ReplyRecords: all.statements.length,
          TotalRecords: all.statements.length,
          PreviousGrossBalance: all.previous[0],
          PreviousGrossBalanceSign: all.previous[1],
          NewGrossBalance: all.next[0],
          NewGrossBalanceSign: all.next[1],
          Statements: all.statements,
        },
        null,
        2,
      );
    },

    // The details of the transactions `ids`. The bank takes one id per call, so
    // this makes `concurrency` calls at a time. Resolves to JSON text with
    // `entries`, a list of `{ id, json }` with the bank's response for each id,
    // as JSON text, in the order of `ids`; `failed`, the number of transactions
    // the bank gave no details for; and `stopped`, the HTTP status that made it
    // give up early, or null.
    //
    // The caller makes this call for a few ids at a time: one call may take no
    // longer than the browser allows, and what it returned is safe even if the
    // page is gone by the next.
    fetchDetails: async ({ iban, ids, concurrency }) => {
      const post = await connect(iban);
      const pending = [...new Set(ids)];
      const responses = [];
      let next = 0;
      let failed = 0;
      let stopped = null;

      const worker = async () => {
        while (stopped === null && next < pending.length) {
          const index = next++;
          const id = pending[index];
          try {
            const response = await post({ GetDetails: { UN: id } });
            const [statement] = response.Statements || [];
            if (response.ResultCode !== 0 || !statement || statement.TransactionUN !== id) throw response;
            responses[index] = { id, json: JSON.stringify(response, null, 2) };
          } catch (error) {
            // A dead session (401) or the bank's edge blocking us (403) would
            // fail every remaining call, and going on only makes a block worse.
            if (error && (error.status === 401 || error.status === 403)) stopped = error.status;
            else failed++;
          }
          // Go easy on the bank: it blocks when asked for too much, too fast.
          await new Promise((resolve) => setTimeout(resolve, pause));
        }
      };

      await Promise.all(Array.from({ length: concurrency }, worker));
      // `responses` has holes where there was none.
      return JSON.stringify({ entries: responses.filter(Boolean), failed, stopped });
    },

    // The monthly statements the bank keeps for the account, as its JSON text:
    // what the "Copies" tab of the account lists, newest first, each with the
    // `EstatementID` that `fetchEStatement` takes.
    listEStatements: async ({ iban }) => {
      const post = await connect(iban);
      const response = await post({}, "getAccountEStatements");
      if (response.ResultCode !== 0) throw new Error("the list of statements has ResultCode " + response.ResultCode);
      return JSON.stringify(response, null, 2);
    },

    // The PDF of the monthly statement `id`, an `EstatementID` of `listEStatements`,
    // as JSON text: `bytes`, its size, and `base64`, its content. The app's own
    // button does this with a form that it posts in a new window; so does this,
    // with the anti-forgery token that the page carries.
    //
    // Checked before it is returned: when the session has ended the bank may
    // still answer 200, with a page instead of the PDF.
    fetchEStatement: async ({ id }) => {
      await ready();
      const token = document.querySelector("input[name='__RequestVerificationToken']")?.value;
      if (!token) throw new Error("the page has no anti-forgery token");
      const form = new URLSearchParams({
        __RequestVerificationToken: token,
        Source: "0",
        "AccountFilter.EStatementID": id,
        Target: "0",
        ActivityDateTime: new Date().toISOString(),
        UniqueIdentifier: crypto.randomUUID(),
      });
      return logged("statement pdf", async () => {
        const response = await fetch("/myAlphaWeb/business/file/GetEStatement", {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: form,
        });
        if (!response.ok) throw Object.assign(new Error("HTTP " + response.status), { status: response.status });
        const type = response.headers.get("content-type") || "";
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (!type.includes("application/pdf")) throw new Error("not a PDF, but " + JSON.stringify(type));
        if (latin1(bytes.subarray(0, 5)) !== "%PDF-") throw new Error("the content does not start like a PDF");
        if (!latin1(bytes.subarray(-1024)).includes("%%EOF")) throw new Error("the PDF is cut short, it has no %%EOF");
        const length = response.headers.get("content-length");
        if (length !== null && Number(length) !== bytes.length) {
          throw new Error("the PDF is " + bytes.length + " bytes, but the bank said " + length);
        }
        return JSON.stringify({ bytes: bytes.length, base64: base64(bytes) });
      });
    },
  };
})()
