// Transport spike: drive the Stagehand v4 extension over raw CDP, with no Stagehand SDK.
// Proves: extension load over a --remote-debugging-port websocket, service-worker attach,
// JSON-RPC through Runtime.addBinding / Runtime.evaluate, and llm.generate reaching the host.
// The llm.generate answer is a fixed stub: this measures the wire, not model quality.
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fsSync from "node:fs";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";

const SP = path.dirname(new URL(import.meta.url).pathname);
const EXT = path.join(SP, "package/dist/extension");
const PROFILE = path.join(SP, "profile");
const OUT = path.join(SP, "out");
const BIN = process.env.CHROME_BIN;
// Chrome names an unpacked extension after the SHA-256 of its real path (first 32 hex digits, 0-f -> a-p).
const EXT_ID = crypto.createHash("sha256").update(fsSync.realpathSync(EXT)).digest("hex").slice(0, 32)
  .split("").map((h) => String.fromCharCode(97 + parseInt(h, 16))).join("");
// ORIGINS=none omits the flag; ORIGINS=extension allows only this extension; ORIGINS=any is Stagehand's default.
const ORIGINS = process.env.ORIGINS ?? "extension";
const originFlag = { none: [], extension: [`--remote-allow-origins=chrome-extension://${EXT_ID}`], any: ["--remote-allow-origins=*"] }[ORIGINS];
const t0 = Date.now();
const log = (...a) => console.log(`+${String(Date.now() - t0).padStart(5)}ms`, ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const FIXTURE = `<!doctype html><html><head><title>spike fixture</title></head><body>
<h1>Order form</h1><p>Plan price: 42 USD</p>
<label for="email">Email</label><input id="email" type="email">
<button id="submit" onclick="document.body.dataset.clicked='yes'">Submit order</button>
</body></html>`;
const server = http.createServer((_, res) => { res.setHeader("content-type", "text/html"); res.end(FIXTURE); });
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const fixtureUrl = `http://127.0.0.1:${server.address().port}/`;

await fs.rm(PROFILE, { recursive: true, force: true });
await fs.mkdir(PROFILE, { recursive: true });
await fs.mkdir(OUT, { recursive: true });
const chrome = spawn(BIN, [
  "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${PROFILE}`,
  "--enable-unsafe-extension-debugging", ...originFlag,
  "--no-first-run", "--no-default-browser-check", "--window-size=1280,800", "about:blank",
], { stdio: ["ignore", "ignore", "ignore"] });
process.on("exit", () => chrome.kill("SIGTERM"));
process.on("uncaughtException", (e) => { console.error("FATAL", e.message); process.exit(1); });

let port, wsPath;
for (let i = 0; i < 100 && !port; i++) {
  try { [port, wsPath] = (await fs.readFile(path.join(PROFILE, "DevToolsActivePort"), "utf8")).trim().split("\n"); }
  catch { await sleep(100); }
}
if (!port) throw new Error("DevToolsActivePort never appeared");
log("devtools port", port);

const ws = new WebSocket(`ws://127.0.0.1:${port}${wsPath}`);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let cdpId = 1; const cdpPending = new Map(); const listeners = [];
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id !== undefined && cdpPending.has(msg.id)) {
    const { res, rej } = cdpPending.get(msg.id); cdpPending.delete(msg.id);
    msg.error ? rej(new Error(`${msg.error.code} ${msg.error.message}`)) : res(msg.result);
  } else listeners.forEach((f) => f(msg));
};
const cdp = (method, params = {}, sessionId) => new Promise((res, rej) => {
  const id = cdpId++; cdpPending.set(id, { res, rej });
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
});

log("browser", (await cdp("Browser.getVersion")).product);
const { id: extId } = await cdp("Extensions.loadUnpacked", { path: EXT });
log("Extensions.loadUnpacked ->", extId, extId === EXT_ID ? "(matches id computed from path)" : `(computed ${EXT_ID})`, "origins:", ORIGINS);

let sw;
for (let i = 0; i < 100 && !sw; i++) {
  const { targetInfos } = await cdp("Target.getTargets");
  sw = targetInfos.find((t) => t.type === "service_worker" && t.url.startsWith(`chrome-extension://${extId}/`));
  if (!sw) await sleep(100);
}
if (!sw) throw new Error("service worker target never appeared");
const { sessionId } = await cdp("Target.attachToTarget", { targetId: sw.targetId, flatten: true });
await cdp("Runtime.enable", {}, sessionId);
await cdp("Runtime.addBinding", { name: "__stagehandSendToHost" }, sessionId);

const ours = await cdp("Runtime.evaluate", {
  expression: `new Promise((resolve) => {
  const check = () => typeof globalThis.__stagehandReceiveFromHost === "function"
    ? resolve(globalThis.__stagehand_runtime ?? null)
    : setTimeout(check, 50);
  check();
})`,
  awaitPromise: true, returnByValue: true,
}, sessionId);
log("masc readiness expression ->", JSON.stringify(ours));
await sleep(1000);
const later = await cdp("Runtime.evaluate", { expression: "globalThis.__stagehand_runtime ?? null", returnByValue: true }, sessionId);
log("marker one second later ->", JSON.stringify(later));
const keys = await cdp("Runtime.evaluate", { expression: "Object.getOwnPropertyNames(globalThis).filter((k) => k.toLowerCase().includes('stagehand'))", returnByValue: true }, sessionId);
log("stagehand globals ->", JSON.stringify(keys.result.value));
chrome.kill("SIGTERM");
process.exit(0);
