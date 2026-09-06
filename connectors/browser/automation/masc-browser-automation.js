#!/usr/bin/env node
// masc browser lane — automation backend (A).
//
// Long-polls the masc server with x-lane: automation and drives a
// Playwright Firefox build: a keeper-dedicated browser instance, profile at
// <base>/.masc/browser-lane/profile, separate from the operator's session
// (stock Firefox cannot be driven by Playwright — measured 2026-09-06).
//
// One persistent context, pages addressed by the snapshot index from
// tabs.list. Verbs are a closed set: unknown verbs are refused by name.
//
// Setup:  npm install playwright && npx playwright install firefox
// Run:    node masc-browser-automation.js [--base /path]

"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
function argOf(name) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : null;
}
const BASE = argOf("--base") || process.env.MASC_BROWSER_LANE_BASE || "/tmp/masc-browser-lane";
const POLL_URL = process.env.MASC_BROWSER_LANE_POLL || "http://127.0.0.1:8935/browser-lane/poll";
const TOKEN = fs.existsSync(`${BASE}/token`) ? fs.readFileSync(`${BASE}/token`, "utf8").trim() : process.env.MASC_BROWSER_LANE_TOKEN || "";
const PROFILE_DIR = path.join(BASE, "profile");
const READ_CAP = 50000;
const GOTO_TIMEOUT_MS = 30000;

let ctx = null; // Playwright BrowserContext | null
let pw = null;

function log(line) {
  process.stderr.write(`automation: ${line}\n`);
}

// --- lane transport (same wire as the live-lane host) ------------------------

function post(p, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(POLL_URL);
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname.replace(/\/poll$/, "") + p,
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-lane": "automation",
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
    req.setTimeout(60000, () => req.destroy(new Error("poll_timeout")));
    req.end(JSON.stringify(body ?? {}));
  });
}

async function answer(id, ok, data, error) {
  try {
    await post("/result", { id, lane: "automation", ok, data: data ?? null, error: error ?? null });
  } catch (e) {
    log(`result post failed: ${e.message}`);
  }
}

// --- verbs --------------------------------------------------------------------

async function ensurePw() {
  if (!pw) pw = require("playwright");
  return pw;
}

async function sessionOpen(a) {
  await ensurePw();
  if (ctx) return { already_open: true, pages: ctx.pages().length };
  fs.mkdirSync(path.dirname(PROFILE_DIR), { recursive: true });
  ctx = await pw.firefox.launchPersistentContext(PROFILE_DIR, {
    headless: a?.headless !== false,
  });
  return { open: true, headless: a?.headless !== false, pages: ctx.pages().length };
}

async function sessionClose() {
  if (!ctx) return { already_closed: true };
  const c = ctx;
  ctx = null;
  await c.close();
  return { closed: true };
}

function pageByIndex(i) {
  if (!ctx) throw new Error("session_closed");
  const pages = ctx.pages();
  const idx = typeof i === "number" && i >= 0 && i < pages.length ? i : pages.length - 1;
  const page = pages[idx];
  if (!page) throw new Error("no_page");
  return { page, index: idx, pages: pages.length };
}

async function tabsList() {
  if (!ctx) throw new Error("session_closed");
  const pages = ctx.pages();
  return pages.map((p, i) => ({
    id: i,
    index: i,
    active: i === pages.length - 1,
    title: null,
    url: p.url(),
  }));
}

async function pageGoto(a) {
  if (typeof a?.url !== "string" || !/^https?:\/\//.test(a.url)) throw new Error("bad_url");
  const { page, index } = pageByIndex(a?.tabId ?? undefined);
  const res = await page.goto(a.url, { waitUntil: "domcontentloaded", timeout: GOTO_TIMEOUT_MS });
  return { tabId: index, url: page.url(), title: await page.title(), status: res ? res.status() : null };
}

async function pageRead(a) {
  const { page, index } = pageByIndex(a?.tabId ?? undefined);
  const text = (await page.evaluate(() => (document.body ? document.body.innerText : ""))) || "";
  const cap = typeof a?.maxChars === "number" ? a.maxChars : READ_CAP;
  return {
    tabId: index,
    url: page.url(),
    title: await page.title(),
    text: text.length > cap ? text.slice(0, cap) + `\n[TRUNCATED ${text.length} chars]` : text,
    chars: text.length,
  };
}

async function run(verb, a) {
  switch (verb) {
    case "session.open": return sessionOpen(a);
    case "session.close": return sessionClose();
    case "tabs.list": return tabsList();
    case "page.goto": return pageGoto(a);
    case "page.read": return pageRead(a);
    // page.read/tabs.list are shared with the live lane; click/submit are
    // deliberately absent — they arrive with the act-gate design, not before.
    default: throw new Error(`unknown_verb:${verb}`);
  }
}

// --- main loop ------------------------------------------------------------------

(async () => {
  log(`lane automation polling ${POLL_URL} (profile ${PROFILE_DIR})`);
  for (;;) {
    let reply;
    try {
      reply = await post("/poll", {});
    } catch (e) {
      log(`poll failed (${e.message}); retry in 5s`);
      await new Promise((r) => setTimeout(r, 5000));
      continue;
    }
    if (reply.status !== 200) {
      log(`poll status ${reply.status}; retry in 5s`);
      await new Promise((r) => setTimeout(r, 5000));
      continue;
    }
    let cmd = null;
    try { cmd = JSON.parse(reply.body); } catch { continue; }
    if (!cmd || !cmd.id) continue;
    try {
      answer(cmd.id, true, await run(cmd.verb, cmd.args));
    } catch (e) {
      answer(cmd.id, false, null, String(e?.message ?? e));
    }
  }
})();
