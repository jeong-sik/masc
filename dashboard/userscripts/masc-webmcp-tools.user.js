// ==UserScript==
// @name         masc WebMCP read tools (experimental)
// @namespace    masc.webmcp
// @version      0.1.0
// @description  Register read-only WebMCP tools on a logged-in page so a masc keeper can read authenticated state without a token leaving the browser. RFC-webmcp-capability-lanes Lane C.
// @match        *://*/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==
//
// EXPERIMENTAL — read-only only. This script exists to prove the credential
// delegation pattern: a tool's implementation runs in the page, so it uses the
// page's own session (cookies) and no token is ever handed to masc. A keeper
// calls it through keeper_webmcp_call.
//
// The framework enforces read-only by construction: registerMascReadTool wraps
// a `read` function and there is no write counterpart here. Opening an
// authenticated write is a separate, gated step (RFC §2.3) — do not add a
// registerMascWriteTool to this file.
//
// Install: paste into Tampermonkey, or load in a page with
// `--enable-features=WebMCP`. It no-ops on browsers without document.modelContext.

(function () {
  'use strict';

  const mc = typeof document !== 'undefined' ? document.modelContext : null;
  if (!mc || typeof mc.registerTool !== 'function') {
    // Not a WebMCP browser (or the flag is off). Silent no-op by design.
    return;
  }

  /**
   * Registers one read-only WebMCP tool.
   *
   * @param {object}   spec
   * @param {string}   spec.name         tool name (letters, digits, _, -, .)
   * @param {string}   spec.description  what a keeper reads by calling it
   * @param {object}   spec.inputSchema  JSON Schema for the arguments (may be empty)
   * @param {function} spec.read         async (args) => JSON-serializable value.
   *                                     Runs in page context: use the page's own
   *                                     fetch/cookies for authenticated reads.
   *                                     MUST NOT mutate server state.
   * @param {string[]} [spec.exposedTo]  optional secure origins allowed to call
   *                                     it when this page is framed (default:
   *                                     same-origin only).
   */
  function registerMascReadTool(spec) {
    const { name, description, inputSchema, read, exposedTo } = spec;
    if (typeof read !== 'function') {
      throw new Error(`registerMascReadTool(${name}): read must be a function`);
    }
    const registration = {
      name,
      description: `[read-only] ${description}`,
      inputSchema: inputSchema || { type: 'object', properties: {}, additionalProperties: false },
      async execute(args) {
        const value = await read(args || {});
        return { content: [{ type: 'text', text: JSON.stringify(value) }] };
      },
    };
    if (Array.isArray(exposedTo) && exposedTo.length > 0) registration.exposedTo = exposedTo;
    return Promise.resolve(mc.registerTool(registration));
  }

  // Expose for page-specific companion scripts that register their own reads.
  window.registerMascReadTool = registerMascReadTool;

  // ── Worked example (safe, no network) ───────────────────────────────────
  // Reads DOM state only, so it runs anywhere without touching credentials.
  // It proves the round trip; the credentialed-read pattern is the template
  // below it, deliberately left inert.
  registerMascReadTool({
    name: 'page_read_headings',
    description: "the current page's visible heading outline (h1-h3 text)",
    read: () =>
      [...document.querySelectorAll('h1, h2, h3')]
        .map((el) => ({ level: el.tagName.toLowerCase(), text: el.textContent.trim() }))
        .filter((h) => h.text.length > 0),
  }).then(
    () => console.info('[masc-webmcp] registered page_read_headings'),
    (err) => console.warn('[masc-webmcp] registration failed', err),
  );

  // ── Credential delegation template (INERT — copy into a page companion) ──
  // This is Lane C's actual payoff. Fill in a real same-origin JSON endpoint on
  // a logged-in page. The fetch carries the page's session cookies, so a keeper
  // reads authenticated data with no token stored in masc. Keep it read-only.
  //
  // registerMascReadTool({
  //   name: 'admin_read_pending_queue',
  //   description: 'the pending items in the internal admin queue',
  //   inputSchema: { type: 'object', properties: { limit: { type: 'integer' } }, additionalProperties: false },
  //   read: async ({ limit = 20 }) => {
  //     const res = await fetch(`/api/admin/queue?limit=${limit}`, { credentials: 'include' });
  //     if (!res.ok) throw new Error(`queue read failed: ${res.status}`);
  //     return res.json();
  //   },
  // });
})();
