// A stand-in for the session routes of the account server, so a real browser
// can show the console in the states of a signed-in person without a GitHub
// login. The page of the console, its files and their response headers (the
// policy included) are the bytes a real server answered, read from FILES_DIR;
// only the JSON below is made up. Not a test of the server.
// usage: node console-mock.mjs FILES_DIR PORT
//   FILES_DIR/routes.json maps an address to the name of a saved answer
//   (NAME.hdr, NAME.body), as console-layer.sh writes it.
// Addresses for the script that drives the page:
//   /__scenario/<name>  answers the session routes as in that case from now on
//   /__seen             every request of the session routes since the scenario
//   /__rotate[?user=…]  replaces the session as another tab that signs in
//                       again does: a new CSRF token, and another person when
//                       `user` is given
//   /__hold, /__release the session routes wait between the two, so a page
//                       can be measured while it reads
import fs from "node:fs";
import http from "node:http";

const [filesDir, portText] = process.argv.slice(2);
const port = Number(portText);
const routes = JSON.parse(fs.readFileSync(`${filesDir}/routes.json`, "utf8"));

function saved(name) {
  const header = fs.readFileSync(`${filesDir}/${name}.hdr`, "utf8").replace(/\r/g, "").split("\n");
  const headers = {};
  for (const line of header.slice(1)) {
    const cut = line.indexOf(": ");
    if (cut > 0 && line.slice(0, cut).toLowerCase() !== "content-length") headers[line.slice(0, cut).toLowerCase()] = line.slice(cut + 2);
  }
  return { headers, body: fs.readFileSync(`${filesDir}/${name}.body`) };
}

// What the session routes answer in each case. The sentences are the ones of
// the server (lib/auth/login_routes.ml, lib/auth/authz_browser_request.ml,
// lib/auth_gate.ml).
const unread = { status: 503, error: "The server cannot read its accounts right now. Try again later." };
const otherToken = { status: 403, error: "the CSRF token is not the one of the session" };
const scenarios = {
  signed_out: { session: { status: 401, error: "no session cookie came with the request" }, role: null, logout: 401 },
  member: { session: { status: 200 }, role: "worker", logout: 204 },
  admin: { session: { status: 200 }, role: "admin", logout: 204 },
  session_unread: { session: unread, role: "worker", logout: 503 },
  signout_refused: { session: { status: 200 }, role: "worker", logout: 503 },
  // whoami names another person than the session, as when another tab signs
  // in between the two requests.
  account_changed: { session: { status: 200 }, role: "worker", logout: 204, whoamiUser: "usr_01JCMOTHER0000" },
  // The subscriptions panel (L3d) in each case: nothing connected, accounts
  // of each kind, and a reading the server refuses.
  member_panel_none: { session: { status: 200 }, role: "worker", logout: 204, panel: "none" },
  member_panel_each: { session: { status: 200 }, role: "worker", logout: 204, panel: "each" },
  member_panel_unread: { session: { status: 200 }, role: "worker", logout: 204, panel: "unread" },
  admin_panel_each: { session: { status: 200 }, role: "admin", logout: 204, panel: "each" },
};

// What the two routes of the panel answer, in the shapes of
// lib/server/server_person_integrations.ml and lib/auth_preview.ml
// (provider_accounts). One model id is one long word, to see that a narrow
// window breaks it rather than scrolls.
const longModel = "claude-code-sonnet-thinking-high-effort-with-a-long-identifier-2026";
const offered = {
  integrations: [
    { integration_id: "claude_code", display_name: "Claude Code", models: ["claude-sonnet-5", longModel], calls: "allowed" },
    { integration_id: "codex", display_name: "Codex", models: ["gpt-5.5"], calls: "refused", refusal: "native_tools_reach_other_homes" },
  ],
};
const id = (c) => c.repeat(64);
const runtime = (account, model, fact) => ({ runtime_id: `${id(account)}.${model}`, provider_account_id: id(account), ...fact });
const owned = {
  none: { provider_accounts: [], runtimes: [] },
  each: {
    provider_accounts: [
      { provider_account_id: id("a"), integration_id: "claude_code" },
      { provider_account_id: id("b"), integration_id: "codex" },
      { provider_account_id: id("c"), integration_id: "muse" },
      { provider_account_id: id("d"), integration_id: null, unread: "login_receipt_missing" },
      { provider_account_id: id("e"), integration_id: "claude_code" },
    ],
    runtimes: [
      runtime("a", "claude-sonnet-5", { model: "claude-sonnet-5" }),
      runtime("a", longModel, { model: longModel }),
      runtime("a", "claude-opus-9", { model: null, unread: "runtime_not_bound" }),
      runtime("b", "gpt-5.5", { model: "gpt-5.5" }),
      runtime("c", "muse-1", { model: null, unread: "template_not_declared" }),
      runtime("d", "claude-sonnet-5", { model: null, unread: "account_integration_unread" }),
    ],
  },
};

async function panelRoutes(req, res, path) {
  if (held !== null) await new Promise((release) => held.push(release));
  if (req.method !== "GET") return json(res, 405, { error: "method not allowed" });
  if (scenario.session.status === 401) return json(res, 401, { error: "the route needs a credential" });
  const panel = scenario.panel ?? "none";
  if (path === "/api/v1/auth/integrations") {
    if (panel === "unread") return json(res, 503, { error: "The workspace configuration could not be read." });
    return json(res, 200, offered);
  }
  return json(res, 200, owned[panel === "each" ? "each" : "none"]);
}
const firstSession = { user: "usr_01JCM8P0Y4A7M2", token: "mock-csrf-token" };
let scenario = scenarios.signed_out;
let session = firstSession;
// Every request of the session routes, for the script that drives the page.
let seen = [];
// The answers that wait for /__release, or null when nothing is held.
let held = null;

function json(res, status, value) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(value));
}

async function sessionRoutes(req, res, path) {
  if (held !== null) await new Promise((release) => held.push(release));
  if (req.method === "GET" && path === "/auth/session") {
    if (scenario.session.status !== 200) return json(res, scenario.session.status, { error: scenario.session.error });
    return json(res, 200, { user_id: session.user, expires_at_ms: Date.now() + 8 * 3600000, csrf_token: session.token });
  }
  if (req.method === "GET" && path === "/api/v1/auth/whoami") {
    if (scenario.session.status === 401) return json(res, 401, { error: "the route needs a credential" });
    if (scenario.session.status !== 200) return json(res, scenario.session.status, { error: scenario.session.error });
    return json(res, 200, {
      principal: { kind: "human", id: scenario.whoamiUser ?? session.user },
      role: scenario.role,
      binding: { kind: "session", id: "ses_01JCMB3N8V5C1X" },
    });
  }
  if (req.method === "POST" && path === "/auth/logout") {
    if (scenario.logout === 204) {
      // The server holds one token per session and refuses any other.
      if (req.headers["x-masc-csrf-token"] !== session.token) return json(res, otherToken.status, { error: otherToken.error });
      scenario = scenarios.signed_out;
      res.writeHead(204);
      return res.end();
    }
    if (scenario.logout === 401) return json(res, 401, { error: "no session cookie came with the request" });
    return json(res, scenario.logout, { error: unread.error });
  }
  return json(res, 405, { error: "method not allowed" });
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    const path = url.pathname;
    if (path.startsWith("/__scenario/")) {
      const name = path.slice("/__scenario/".length);
      if (!(name in scenarios)) return json(res, 404, { error: "no such scenario" });
      scenario = scenarios[name];
      session = firstSession;
      seen = [];
      return json(res, 200, { scenario: name });
    }
    if (path === "/__seen") return json(res, 200, seen);
    if (path === "/__rotate") {
      session = { user: url.searchParams.get("user") ?? session.user, token: `${session.token}-again` };
      return json(res, 200, session);
    }
    if (path === "/__hold") {
      held = held ?? [];
      return json(res, 200, { held: true });
    }
    if (path === "/__release") {
      const waiting = held ?? [];
      held = null;
      for (const release of waiting) release();
      return json(res, 200, { released: waiting.length });
    }
    if (req.method === "GET" && path in routes) {
      const answer = saved(routes[path]);
      // The control: the same page under a policy that names no source of a
      // sheet, so the browser refuses both sheets and reports each.
      if (url.searchParams.has("control"))
        answer.headers["content-security-policy"] = answer.headers["content-security-policy"].replace("style-src 'self'; ", "");
      res.writeHead(200, answer.headers);
      return res.end(answer.body);
    }
    if (path === "/api/v1/auth/integrations" || path === "/api/v1/auth/provider-accounts") {
      seen.push({ method: req.method, path, csrf: req.headers["x-masc-csrf-token"] ?? null, authorization: "authorization" in req.headers });
      return void panelRoutes(req, res, path);
    }
    if (path === "/auth/session" || path === "/api/v1/auth/whoami" || path === "/auth/logout") {
      seen.push({ method: req.method, path, csrf: req.headers["x-masc-csrf-token"] ?? null, authorization: "authorization" in req.headers });
      return void sessionRoutes(req, res, path);
    }
    json(res, 404, { error: "not found" });
  })
  .listen(port, "127.0.0.1", () => console.log(`console mock on http://127.0.0.1:${port} files=${filesDir}`));
