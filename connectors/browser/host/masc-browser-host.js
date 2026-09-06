#!/usr/bin/env node
// masc browser lane — native messaging host (B backend).
//
// The browser launches this process and speaks native messaging on
// stdin/stdout: each frame is 4-byte little-endian length + UTF-8 JSON.
// Two modes:
//   --self-test  send one tabs.list to the extension, print the reply, exit
//   (default)    long-poll the masc server for lane commands and bridge them
//
// The lane server endpoint does not exist yet on this branch; the default
// mode retries until it does, so the host can be installed ahead of the
// server work.

"use strict";

const http = require("http");

const POLL_URL = process.env.MASC_BROWSER_LANE_POLL || "http://127.0.0.1:8935/browser-lane/poll";
const LANE = process.env.MASC_BROWSER_LANE_ID || "live";
const TOKEN = process.env.MASC_BROWSER_LANE_TOKEN || "";
const POLL_TIMEOUT_MS = 55000;
const VERB_TIMEOUT_MS = 20000;

// --- native messaging framing -------------------------------------------------

let buf = Buffer.alloc(0);
const frameHandlers = [];

function writeFrame(obj) {
  const payload = Buffer.from(JSON.stringify(obj), "utf8");
  const head = Buffer.alloc(4);
  head.writeUInt32LE(payload.length, 0);
  process.stdout.write(Buffer.concat([head, payload]));
}

function pushFrame(obj) {
  writeFrame(obj);
}

function onFrame(handler) {
  frameHandlers.push(handler);
}

process.stdin.on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  while (buf.length >= 4) {
    const len = buf.readUInt32LE(0);
    if (buf.length < 4 + len) break;
    const payload = buf.subarray(4, 4 + len);
    buf = buf.subarray(4 + len);
    let msg = null;
    try {
      msg = JSON.parse(payload.toString("utf8"));
    } catch {
      process.stderr.write("host: undecodable frame from extension\n");
      continue;
    }
    for (const h of frameHandlers) h(msg);
  }
});

// --- verb round-trip to the extension ------------------------------------------

const pending = new Map(); // id -> {resolve, timer}

onFrame((msg) => {
  const entry = msg && pending.get(msg.id);
  if (!entry) return;
  clearTimeout(entry.timer);
  pending.delete(msg.id);
  entry.resolve(msg);
});

function askExtension(verb, args, timeoutMs = VERB_TIMEOUT_MS) {
  return new Promise((resolve) => {
    const id = `h${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ id, ok: false, error: "verb_timeout" });
    }, timeoutMs);
    pending.set(id, { resolve, timer });
    pushFrame({ id, verb, args: args ?? {} });
  });
}

// --- self-test -------------------------------------------------------------------

if (process.argv.includes("--self-test") || process.env.MASC_BROWSER_LANE_SELFTEST === "1") {
  (async () => {
    const fs = require("fs");
    const reply = await askExtension("tabs.list");
    const bad = await askExtension("nope");
    const verdict = {
      tabs_ok: !!reply.ok,
      tabs_sample: (reply.data ?? []).slice(0, 3),
      unknown_refused: bad.error === "unknown_verb:nope",
      at: new Date().toISOString(),
    };
    try {
      fs.mkdirSync("/tmp/masc-browser-lane", { recursive: true });
      fs.writeFileSync("/tmp/masc-browser-lane/selftest.json", JSON.stringify(verdict, null, 2));
    } catch {}
    process.stderr.write(`self-test: ${JSON.stringify(verdict).slice(0, 1500)}\n`);
    process.exit(verdict.tabs_ok && verdict.unknown_refused ? 0 : 1);
  })();
  return;
}

// --- lane mode ---------------------------------------------------------------------

function post(path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(POLL_URL);
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname.replace(/\/poll$/, "") + path,
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-lane": LANE,
          ...(TOKEN ? { "x-lane-token": TOKEN } : {}),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => resolve({ status: res.statusCode, body: data }));
      }
    );
    req.on("error", reject);
    req.setTimeout(POLL_TIMEOUT_MS, () => req.destroy(new Error("poll_timeout")));
    req.end(JSON.stringify(body ?? {}));
  });
}

async function laneLoop() {
  for (;;) {
    let reply;
    try {
      reply = await post("/poll", {});
    } catch (e) {
      process.stderr.write(`host: poll failed (${e.message}); retry in 5s\n`);
      await new Promise((r) => setTimeout(r, 5000));
      continue;
    }
    if (reply.status !== 200) {
      process.stderr.write(`host: poll status ${reply.status}; retry in 5s\n`);
      await new Promise((r) => setTimeout(r, 5000));
      continue;
    }
    let cmd = null;
    try {
      cmd = JSON.parse(reply.body);
    } catch {
      continue; // empty long-poll window; loop again
    }
    if (!cmd || !cmd.id) continue;
    const answer = await askExtension(cmd.verb, cmd.args);
    try {
      await post("/result", { id: cmd.id, lane: LANE, ok: answer.ok, data: answer.data, error: answer.error });
    } catch (e) {
      process.stderr.write(`host: result post failed: ${e.message}\n`);
    }
  }
}

process.stderr.write(`host: lane ${LANE} polling ${POLL_URL}\n`);
laneLoop();
