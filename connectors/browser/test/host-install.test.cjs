"use strict";

// No browser is launched. The HTTP peer and native-messaging extension are
// fixtures; tab/page payloads below never come from the operator's session.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { spawn, spawnSync } = require("node:child_process");
const { once } = require("node:events");
const crypto = require("node:crypto");

const source = path.resolve(__dirname, "..");
const tokenA = "fixture-account-a-1234567890123456";
const tokenB = "fixture-account-b-1234567890123456";

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "masc host ' test "));
  const home = path.join(root, "gui home");
  const checkout = path.join(root, "checkout with spaces");
  const base = path.join(root, "runtime base");
  fs.mkdirSync(home);
  fs.mkdirSync(base);
  fs.cpSync(source, checkout, { recursive: true });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return { root, home, checkout, base };
}

function environment(home, extra = {}) {
  return { HOME: home, PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`, ...extra };
}

function snapshot(dir) {
  return fs.readdirSync(dir).sort().flatMap((name) => {
    const full = path.join(dir, name);
    return fs.statSync(full).isDirectory()
      ? snapshot(full).map(([child, hash]) => [path.join(name, child), hash])
      : [[name, crypto.createHash("sha256").update(fs.readFileSync(full)).digest("hex")]];
  });
}

function install(f, extra = {}) {
  const result = spawnSync("/bin/bash", [path.join(f.checkout, "install-host.sh")], {
    env: environment(f.home, extra), encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  const manifestPath = path.join(f.home, "Library", "Application Support", "Mozilla", "NativeMessagingHosts", "masc_browser_host.json");
  return { manifestPath, manifest: JSON.parse(fs.readFileSync(manifestPath, "utf8")), output: result.stdout };
}

function queue() {
  const values = [];
  const waiters = [];
  return {
    push(value) { const waiter = waiters.shift(); if (waiter) waiter(value); else values.push(value); },
    next() { return values.length ? Promise.resolve(values.shift()) : new Promise((resolve) => waiters.push(resolve)); },
  };
}

async function serverFixture(t, command = { id: "request-1", verb: "tabs.list", args: {} }) {
  const requests = [];
  const incoming = queue();
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      const request = { url: req.url, headers: req.headers, body: JSON.parse(body) };
      requests.push(request);
      incoming.push(request);
      if (req.url === "/browser-lane/result") res.end("{}");
      else if (requests.length === 1) res.end(JSON.stringify(command));
      // The next poll stays open, like the real long-poll server.
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  }));
  return { requests, next: incoming.next, url: `http://127.0.0.1:${server.address().port}/browser-lane/poll` };
}

function processFixture(t, command, args, env) {
  const child = spawn(command, args, { env, stdio: ["pipe", "pipe", "pipe"] });
  const frames = queue();
  const diagnostics = queue();
  let buffer = Buffer.alloc(0);
  child.stdout.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const length = buffer.readUInt32LE(0);
      if (buffer.length < 4 + length) return;
      frames.push(JSON.parse(buffer.subarray(4, 4 + length).toString("utf8")));
      buffer = buffer.subarray(4 + length);
    }
  });
  child.stderr.on("data", (chunk) => diagnostics.push(chunk.toString("utf8")));
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill();
      await exited;
    }
  });
  return {
    child, nextFrame: frames.next,
    async diagnosticContaining(text) {
      for (;;) { const diagnostic = await diagnostics.next(); if (diagnostic.includes(text)) return diagnostic; }
    },
    reply(frame) {
      const body = Buffer.from(JSON.stringify(frame));
      const header = Buffer.alloc(4);
      header.writeUInt32LE(body.length);
      // Fragment the native framing boundary; the host must reassemble it.
      child.stdin.write(header.subarray(0, 2));
      child.stdin.write(Buffer.concat([header.subarray(2), body]));
    },
  };
}

function installedHost(t, f, installation, server, extra = {}) {
  // GUI-like environment: no MASC_BASE_PATH, lane base, terminal token, or
  // Node on PATH. The install-time absolute Node executable/base must work.
  return processFixture(t, installation.manifest.path,
    [installation.manifestPath, "browser-lane@masc.local"],
    { HOME: f.home, PATH: "/usr/bin:/bin", MASC_BROWSER_LANE_POLL: server.url, ...extra });
}

test("installed host survives checkout removal and rotates its file token", { timeout: 10000 }, async (t) => {
  const f = fixture(t);
  const before = snapshot(f.checkout);
  const installation = install(f, { MASC_BASE_PATH: f.base });
  assert.deepEqual(snapshot(f.checkout), before, "installer must not mutate its source tree");
  const lane = path.join(f.base, ".masc", "browser-lane");
  const tokenPath = path.join(lane, "token");
  assert.equal(fs.statSync(tokenPath).mode & 0o777, 0o600);
  assert.equal(fs.readFileSync(tokenPath, "utf8").trim().length, 48);
  assert.deepEqual(installation.manifest.allowed_extensions, ["browser-lane@masc.local"]);
  assert.ok(installation.manifest.path.startsWith(f.home + path.sep));
  assert.ok(!fs.readFileSync(installation.manifest.path, "utf8").includes(f.checkout));
  assert.equal(fs.readFileSync(path.join(path.dirname(installation.manifest.path), "host", "masc-browser-host.js"), "utf8"),
    fs.readFileSync(path.join(f.checkout, "host", "masc-browser-host.js"), "utf8"));
  fs.renameSync(f.checkout, f.checkout + " removed");
  fs.writeFileSync(tokenPath, tokenA + "\n");
  const server = await serverFixture(t);
  const host = installedHost(t, f, installation, server);
  const poll = await server.next();
  assert.equal(poll.headers["x-lane"], "live");
  assert.equal(poll.headers["x-lane-token"], tokenA);
  const frame = await host.nextFrame();
  assert.equal(frame.verb, "tabs.list");
  const rotated = tokenPath + ".rotated";
  fs.writeFileSync(rotated, tokenB + "\n", { mode: 0o600 });
  fs.renameSync(rotated, tokenPath);
  const fixtureTabs = [{ id: 42, title: "Fixture tab", url: "https://fixture.invalid" }];
  host.reply({ id: frame.id, ok: true, data: fixtureTabs });
  const result = await server.next();
  assert.equal(result.url, "/browser-lane/result");
  assert.equal(result.headers["x-lane-token"], tokenB);
  assert.deepEqual(result.body, { id: "request-1", lane: "live", ok: true, data: fixtureTabs });
  assert.equal((await server.next()).headers["x-lane-token"], tokenB);
});

test("explicit lane base installs idempotently and explicit token overrides file", { timeout: 10000 }, async (t) => {
  const f = fixture(t);
  const lane = path.join(f.root, "explicit lane ' directory");
  const settings = { MASC_BASE_PATH: f.base, MASC_BROWSER_LANE_BASE: lane };
  const installation = install(f, settings);
  const tokenPath = path.join(lane, "token");
  fs.writeFileSync(tokenPath, tokenA);
  install(f, settings);
  assert.equal(fs.readFileSync(tokenPath, "utf8"), tokenA, "reinstallation preserves server credential");
  assert.equal(fs.existsSync(path.join(f.base, ".masc")), false);
  const server = await serverFixture(t, { id: "read-1", verb: "page.read", args: { tabId: 42 } });
  const host = installedHost(t, f, installation, server, { MASC_BROWSER_LANE_TOKEN: tokenB });
  assert.equal((await server.next()).headers["x-lane-token"], tokenB);
  const frame = await host.nextFrame();
  assert.deepEqual({ verb: frame.verb, args: frame.args }, { verb: "page.read", args: { tabId: 42 } });
  host.reply({ id: frame.id, ok: true, data: { tabId: 42, text: "Fixture text", chars: 12 } });
  const result = await server.next();
  assert.equal(result.headers["x-lane-token"], tokenB);
  assert.equal(result.body.data.text, "Fixture text");
});

test("missing file or explicit empty token never emits an anonymous poll", { timeout: 10000 }, async (t) => {
  const f = fixture(t);
  const installation = install(f, { MASC_BASE_PATH: f.base });
  const tokenPath = path.join(f.base, ".masc", "browser-lane", "token");
  fs.unlinkSync(tokenPath);
  const server = await serverFixture(t);
  const host = installedHost(t, f, installation, server);
  await host.diagnosticContaining("cannot read browser lane token");
  assert.equal(server.requests.length, 0);
  fs.writeFileSync(tokenPath, tokenA);
  const empty = installedHost(t, f, installation, server, { MASC_BROWSER_LANE_TOKEN: "" });
  await empty.diagnosticContaining("browser lane token must contain at least 16 characters");
  assert.equal(server.requests.length, 0);
});

test("automation shares configured root and environment token precedence", { timeout: 10000 }, async (t) => {
  const f = fixture(t);
  install(f, { MASC_BASE_PATH: f.base });
  const tokenPath = path.join(f.base, ".masc", "browser-lane", "token");
  fs.writeFileSync(tokenPath, tokenA);
  const server = await serverFixture(t, { id: "unknown-1", verb: "fixture.unknown", args: {} });
  processFixture(t, process.execPath, [path.join(f.checkout, "automation", "masc-browser-automation.js")],
    environment(f.home, { MASC_BASE_PATH: f.base, MASC_BROWSER_LANE_POLL: server.url, MASC_BROWSER_LANE_TOKEN: tokenB }));
  const poll = await server.next();
  assert.equal(poll.headers["x-lane"], "automation");
  assert.equal(poll.headers["x-lane-token"], tokenB);
  const result = await server.next();
  assert.equal(result.headers["x-lane-token"], tokenB);
  assert.equal(result.body.error, "unknown_verb:fixture.unknown");
});

test("installation without a declared base fails without writing files", (t) => {
  const f = fixture(t);
  const result = spawnSync("/bin/bash", [path.join(f.checkout, "install-host.sh")], {
    env: environment(f.home), encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /set MASC_BASE_PATH or MASC_BROWSER_LANE_BASE/);
  assert.deepEqual(fs.readdirSync(f.home), []);
});
