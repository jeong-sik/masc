// Transport spike: drive the Stagehand v4 extension over raw CDP, with no Stagehand SDK.
// Proves: extension load over a --remote-debugging-port websocket, service-worker attach,
// JSON-RPC through Runtime.addBinding / Runtime.evaluate, and llm.generate reaching the host.
// The llm.generate answer is a fixed stub: this measures the wire, not model quality.
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";

const SP = path.dirname(new URL(import.meta.url).pathname);
const EXT = path.join(SP, "package/dist/extension");
const PROFILE = path.join(SP, "profile");
const OUT = path.join(SP, "out");
const BIN = process.env.CHROME_BIN;
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
  "--enable-unsafe-extension-debugging", "--remote-allow-origins=*",
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
log("Extensions.loadUnpacked ->", extId);

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
let marker;
for (let i = 0; i < 100; i++) {
  const r = await cdp("Runtime.evaluate", {
    expression: `(() => ({ marker: globalThis.__stagehand_runtime ?? null, hasReceiver: typeof globalThis.__stagehandReceiveFromHost === "function" }))()`,
    returnByValue: true,
  }, sessionId);
  if (r.result.value?.hasReceiver) { marker = r.result.value.marker; break; }
  await sleep(100);
}
log("runtime marker", JSON.stringify(marker));

let rpcId = 1; const rpcPending = new Map(); const serverRequests = [];
const send = (obj) => cdp("Runtime.evaluate", {
  expression: `void globalThis.__stagehandReceiveFromHost(${JSON.stringify(JSON.stringify(obj))}); true`,
  awaitPromise: false, returnByValue: true,
}, sessionId);
const rpc = (method, params) => new Promise((res, rej) => {
  const id = rpcId++; rpcPending.set(id, { res, rej, method });
  send({ jsonrpc: "2.0", id, method, params });
});
listeners.push((msg) => {
  if (msg.method !== "Runtime.bindingCalled" || msg.params.name !== "__stagehandSendToHost") return;
  const m = JSON.parse(msg.params.payload);
  if (m.method === undefined && rpcPending.has(m.id)) {
    const p = rpcPending.get(m.id); rpcPending.delete(m.id);
    m.error ? p.rej(new Error(`${p.method}: ${JSON.stringify(m.error)}`)) : p.res(m.result);
    return;
  }
  if (m.method === undefined) return;
  const bytes = msg.params.payload.length;
  serverRequests.push({ method: m.method, bytes, params: m.params });
  log(`extension -> host request: ${m.method} (${bytes} bytes)`);
  if (m.method !== "llm.generate" || m.id === undefined) {
    if (m.id !== undefined) send({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "spike: not served" } });
    return;
  }
  const rf = m.params.response_format;
  const props = rf?.schema?.properties ? Object.keys(rf.schema.properties) : [];
  log(`  llm.generate: messages=${m.params.messages.length} response_format=${rf?.type ?? "text"} schema_props=[${props}] tools=${m.params.tools?.length ?? 0}`);
  // Stub model, spike only: a real deployment answers through the masc provider runtime.
  const reply = (structured) => send({ jsonrpc: "2.0", id: m.id, result: {
    role: "assistant", content: { type: "text", text: JSON.stringify(structured) },
    output_format: "json_schema", structured_content: structured,
  } });
  const prompt = m.params.messages.flatMap((x) => Array.isArray(x.content) ? x.content : [x.content]).map((b) => b.text ?? "").join("\n");
  if (props.includes("heading")) reply({ heading: "Order form", price: "42 USD" });
  else if (props.includes("completed")) reply({ progress: "heading and price extracted", completed: true });
  else if (props.includes("action")) {
    const line = prompt.split("\n").find((l) => l.includes("button: Submit order"));
    const elementId = line?.match(/\[(\d+-\d+)\]/)?.[1];
    reply({ action: elementId ? { elementId, description: "Submit order button", method: "click", arguments: [] } : null, twoStep: false });
  } else send({ jsonrpc: "2.0", id: m.id, error: { code: -32000, message: "spike: stub has no answer" } });
});

const init = await rpc("stagehand.init", {
  protocol_version: marker?.protocolVersion ?? marker?.protocol_version ?? "unknown",
  client_info: { name: "masc-spike", version: "0.0.0" },
  model: { source: "client" },
  browser_cdp_url: `ws://127.0.0.1:${port}${wsPath}`,
});
log("stagehand.init ->", JSON.stringify(init).slice(0, 300));
const pageId = init.pages?.[0]?.page_id ?? init.pages?.[0]?.id;

const step = async (label, fn) => {
  const s = Date.now();
  try { const r = await fn(); log(`${label} ok (${Date.now() - s}ms)`, JSON.stringify(r).slice(0, 240)); return r; }
  catch (e) { log(`${label} FAILED (${Date.now() - s}ms)`, e.message.slice(0, 300)); return undefined; }
};
await step("page.goto", () => rpc("page.goto", { page_id: pageId, url: fixtureUrl }));
const shot = await step("page.screenshot", () => rpc("page.screenshot", { page_id: pageId }));
const b64 = shot?.data ?? shot?.screenshot ?? shot?.image;
if (typeof b64 === "string") { await fs.writeFile(path.join(OUT, "fixture.png"), Buffer.from(b64, "base64")); log("screenshot saved", path.join(OUT, "fixture.png")); }
await step("stagehand.extract", () => rpc("stagehand.extract", {
  page_id: pageId, instruction: "Extract the page heading and the plan price",
  schema: { type: "object", properties: { heading: { type: "string" }, price: { type: "string" } }, required: ["heading", "price"] },
}));
await step("stagehand.act", () => rpc("stagehand.act", { page_id: pageId, instruction: "click the Submit order button" }));
await step("page.evaluate clicked?", () => rpc("page.evaluate", { page_id: pageId, expression: "document.body.dataset.clicked ?? \"no\"" }));
await step("stagehand.metrics", () => rpc("stagehand.metrics", {}));

await fs.writeFile(path.join(OUT, "server-requests.json"), JSON.stringify(serverRequests, null, 2));
log("recorded extension->host requests:", serverRequests.map((r) => r.method).join(", "));
ws.close(); chrome.kill("SIGTERM"); server.close();
log("done");
