// A stand-in for the account server's JSON routes, so a real browser can render
// the real pages in every state without a GitHub login. The HTML and its
// response headers (CSP included) are the bytes a real server answered, read
// from PAGES_DIR; only the JSON below is made up. Not a test of the server.
// usage: node ux-mock.mjs PAGES_DIR PORT
import fs from "node:fs";
import http from "node:http";

const [pagesDir, portText] = process.argv.slice(2);
const port = Number(portText);

function savedPage(name) {
  const header = fs.readFileSync(`${pagesDir}/${name}.hdr`, "utf8").replace(/\r/g, "").split("\n");
  const headers = {};
  for (const line of header.slice(1)) {
    const cut = line.indexOf(": ");
    if (cut > 0 && line.slice(0, cut).toLowerCase() !== "content-length") headers[line.slice(0, cut)] = line.slice(cut + 2);
  }
  return { headers, body: fs.readFileSync(`${pagesDir}/${name}.body`) };
}

const now = Date.now();
const scenarios = {
  signed_out: { session: null },
  member_new: { session: "worker", accounts: [], runtimes: [], keepers: [], pats: [] },
  member_full: {
    session: "worker",
    accounts: ["pa_01JCM8Q2Z7V4T9", "pa_01JCM9D5R1K8W3"],
    runtimes: [
      { runtime_id: "rt_01JCM8Q9X2B6N4", provider_account_id: "pa_01JCM8Q2Z7V4T9" },
      { runtime_id: "rt_01JCM9DC4H7P2Y", provider_account_id: "pa_01JCM9D5R1K8W3" },
    ],
    keepers: [
      { keeper_id: "scout", runtime_id: "rt_01JCM8Q9X2B6N4" },
      { keeper_id: "archivist", runtime_id: null },
    ],
    pats: [
      { pat_id: "pat_01JCMA1F6S3E8G", status: "open", scope: { runtimes: "all", channels: ["direct"], allowed_effects: ["read_state"] }, expires_at_ms: now + 30 * 86400000 },
      { pat_id: "pat_01JCM7ZK9U2D5Q", status: "revoked", scope: { runtimes: "all", channels: ["direct"], allowed_effects: ["read_state"] }, expires_at_ms: null },
    ],
  },
};
scenarios.admin_full = { ...scenarios.member_full, session: "admin" };
let scenario = scenarios.signed_out;

function json(res, status, value) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(value));
}
function needsSession(res) {
  if (scenario.session !== null) return false;
  json(res, 401, { error: "the route needs a credential" });
  return true;
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    const path = url.pathname;
    if (path.startsWith("/__scenario/")) {
      const name = path.slice("/__scenario/".length);
      if (!(name in scenarios)) return json(res, 404, { error: "no such scenario" });
      scenario = scenarios[name];
      return json(res, 200, { scenario: name });
    }
    if (req.method === "GET" && (path === "/" || path === "/accounts/invite")) {
      const page = savedPage(path === "/" ? "home" : "invite");
      res.writeHead(200, page.headers);
      return res.end(page.body);
    }
    if (path === "/auth/session") {
      if (scenario.session === null) return json(res, 401, { error: "no session cookie came with the request" });
      return json(res, 200, { user_id: "usr_01JCM8P0Y4A7M2", expires_at_ms: now + 8 * 3600000, csrf_token: "mock-csrf-token" });
    }
    if (path === "/api/v1/auth/whoami") {
      if (needsSession(res)) return;
      return json(res, 200, {
        principal: { kind: "human", id: "usr_01JCM8P0Y4A7M2" },
        role: scenario.session,
        binding: { kind: "session", id: "ses_01JCMB3N8V5C1X" },
      });
    }
    if (path === "/api/v1/auth/provider-accounts") {
      if (needsSession(res)) return;
      return json(res, 200, { provider_accounts: scenario.accounts, runtimes: scenario.runtimes });
    }
    if (path === "/api/v1/auth/keepers" && req.method === "GET") {
      if (needsSession(res)) return;
      return json(res, 200, { keepers: scenario.keepers });
    }
    if (path === "/api/v1/auth/pats" && req.method === "GET") {
      if (scenario.session === null) return json(res, 401, { error: "no session cookie came with the request" });
      return json(res, 200, { pats: scenario.pats });
    }
    if (req.method === "POST" && path === "/api/v1/setup/accounts/login") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
      const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
      send("started", { login_id: "login_01JCMC7T2R9H6B" });
      send("output", { text: "Opening browser to sign in...\nIf the browser didn't open, visit:\nhttps://claude.ai/oauth/authorize?code=true&client_id=EXAMPLE&state=EXAMPLE\n\nPaste code here if prompted > " });
      return; // stays open, as a login that waits for the person does
    }
    if (req.method === "POST" && path.startsWith("/api/v1/setup/accounts/login/")) return json(res, 200, { ok: true });
    if (req.method === "POST" && path === "/api/v1/setup/accounts/verify")
      return json(res, 403, { error: "the provider account is not one of this person's" });
    if (req.method === "POST" && path === "/api/v1/auth/keepers") return json(res, 409, { error: "a Keeper of this name exists" });
    if (req.method === "POST" && path === "/api/v1/auth/keepers/assign") return json(res, 200, { keeper_id: "scout", runtime_id: "rt_01JCM8Q9X2B6N4" });
    if (req.method === "POST" && path === "/api/v1/auth/keepers/turn")
      return json(res, 200, { keeper_id: "scout", runtime_id: "rt_01JCM8Q9X2B6N4", model: "example-model", text: "Hello. I read your message and I am ready." });
    if (req.method === "POST" && path === "/api/v1/auth/pats") return json(res, 200, { pat_id: "pat_01JCMD4W7L2F9K", token: "mpat_EXAMPLE_NOT_A_TOKEN" });
    if (req.method === "DELETE" && path.startsWith("/api/v1/auth/pats/")) { res.writeHead(204); return res.end(); }
    if (req.method === "POST" && path === "/api/v1/auth/allowlist") return json(res, 200, { registration_id: "reg_01JCME8X3Q6T1V", previously_deleted: false });
    if (req.method === "DELETE" && path.startsWith("/api/v1/auth/allowlist/")) { res.writeHead(204); return res.end(); }
    if (req.method === "POST" && path === "/auth/logout") { scenario = scenarios.signed_out; res.writeHead(204); return res.end(); }
    json(res, 404, { error: "not found" });
  })
  .listen(port, "127.0.0.1", () => console.log(`mock on http://127.0.0.1:${port} pages=${pagesDir}`));
