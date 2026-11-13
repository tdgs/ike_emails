// Runs in the myAlpha Web login page. Evaluates to an object of functions.
(() => {
  // The page contains two login forms and the first one is hidden, so a plain
  // querySelector matches the wrong inputs. Always take a visible one.
  const visible = (selector) =>
    [...document.querySelectorAll(selector)].find(
      (element) => element.offsetWidth || element.offsetHeight,
    ) ?? null;

  return {
    // The visible element, or null while there is none.
    find: ({ selector }) => visible(selector),

    click: ({ selector }) => visible(selector).click(),

    // Sets the value and fires the events Angular listens to. Typing
    // keystrokes instead depends on the element really having focus.
    fill: ({ selector, value }) => {
      const input = visible(selector);
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(input, value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    },

    // Clicks the logout icon in the header of the logged in app.
    logout: () => visible("a.lo").click(),

    // The body once the browser has left the app, otherwise null.
    leftApp: () => (location.pathname.startsWith("/myAlphaWeb/") ? null : document.body),

    // How a login attempt ended, as JSON text, or null while it has not yet.
    // `{}` when the browser has left the /auth/ pages, so it succeeded, or
    // `{"error": "<the message the page shows>"}` when the bank refused it.
    outcome: () => {
      if (!location.pathname.includes("/auth/")) return JSON.stringify({});
      const error = visible(".login-error");
      return error ? JSON.stringify({ error: error.innerText.trim() }) : null;
    },
  };
})()
