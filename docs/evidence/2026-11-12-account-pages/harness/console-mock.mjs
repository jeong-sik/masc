// A stand-in for the session routes of the account server, so a real browser
// can show the console in the states of a signed-in person without a GitHub
// login. The page of the console, its files and their response headers (the
// policy included) are the bytes a real server answered, read from FILES_DIR;
// only the JSON below is made up. Not a test of the server.
// usage: node console-mock.mjs FILES_DIR PORT
//   FILES_DIR/routes.json maps an address to the name of a saved answer
//   (NAME.hdr, NAME.body), as console-layer.sh writes it.
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
// the server (lib/auth/login_routes.ml, lib/auth_gate.ml).
const unread = { status: 503, error: "The server cannot read its accounts right now. Try again later." };
const scenarios = {
  signed_out: { session: { status: 401, error: "no session cookie came with the request" }, role: null, logout: 401 },
  member: { session: { status: 200 }, role: "worker", logout: 204 },
  admin: { session: { status: 200 }, role: "admin", logout: 204 },
  session_unread: { session: unread, role: "worker", logout: 503 },
  signout_refused: { session: { status: 200 }, role: "worker", logout: 503 },
};
let scenario = scenarios.signed_out;
// Every request of the session routes, for the script that drives the page.
let seen = [];

function json(res, status, value) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(value));
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    const path = url.pathname;
    if (path.startsWith("/__scenario/")) {
      const name = path.slice("/__scenario/".length);
      if (!(name in scenarios)) return json(res, 404, { error: "no such scenario" });
      scenario = scenarios[name];
      seen = [];
      return json(res, 200, { scenario: name });
    }
    if (path === "/__seen") return json(res, 200, seen);
    if (req.method === "GET" && path in routes) {
      const answer = saved(routes[path]);
      // The control: the same page under a policy that names no source of a
      // sheet, so the browser refuses both sheets and reports each.
      if (url.searchParams.has("control"))
        answer.headers["content-security-policy"] = answer.headers["content-security-policy"].replace("style-src 'self'; ", "");
      res.writeHead(200, answer.headers);
      return res.end(answer.body);
    }
    if (path === "/auth/session" || path === "/api/v1/auth/whoami" || path === "/auth/logout")
      seen.push({ method: req.method, path, csrf: req.headers["x-masc-csrf-token"] ?? null, authorization: "authorization" in req.headers });
    if (req.method === "GET" && path === "/auth/session") {
      if (scenario.session.status !== 200) return json(res, scenario.session.status, { error: scenario.session.error });
      return json(res, 200, { user_id: "usr_01JCM8P0Y4A7M2", expires_at_ms: Date.now() + 8 * 3600000, csrf_token: "mock-csrf-token" });
    }
    if (req.method === "GET" && path === "/api/v1/auth/whoami") {
      if (scenario.session.status === 401) return json(res, 401, { error: "the route needs a credential" });
      if (scenario.session.status !== 200) return json(res, scenario.session.status, { error: scenario.session.error });
      return json(res, 200, {
        principal: { kind: "human", id: "usr_01JCM8P0Y4A7M2" },
        role: scenario.role,
        binding: { kind: "session", id: "ses_01JCMB3N8V5C1X" },
      });
    }
    if (req.method === "POST" && path === "/auth/logout") {
      if (scenario.logout === 204) {
        scenario = scenarios.signed_out;
        res.writeHead(204);
        return res.end();
      }
      if (scenario.logout === 401) return json(res, 401, { error: "no session cookie came with the request" });
      return json(res, scenario.logout, { error: unread.error });
    }
    json(res, 404, { error: "not found" });
  })
  .listen(port, "127.0.0.1", () => console.log(`console mock on http://127.0.0.1:${port} files=${filesDir}`));
