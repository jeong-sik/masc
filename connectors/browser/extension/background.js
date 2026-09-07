// masc browser lane — background bridge (B backend).
//
// One native-messaging port to the host process. The host asks, this side
// answers; nothing is pushed proactively. Verbs are a closed set: an unknown
// verb is refused by name, never guessed (the same rule the lane protocol
// holds everywhere).

const HOST_NAME = "masc_browser_host";
const READ_CAP = 50000;

let port = null;
let reconnectTimer = null;

function connect() {
  port = browser.runtime.connectNative(HOST_NAME);
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    // The host is launched by the browser per connection; a quiet retry keeps
    // the lane alive across host restarts without spamming launches.
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, 5000);
  });
}

async function tabsList() {
  const tabs = await browser.tabs.query({});
  return tabs.map((t) => ({
    id: t.id,
    index: t.index,
    windowId: t.windowId,
    active: t.active,
    title: t.title,
    url: t.url,
  }));
}

async function pageRead(args) {
  const tabId =
    typeof args?.tabId === "number"
      ? args.tabId
      : (await browser.tabs.query({ active: true, currentWindow: true }))[0]?.id;
  if (typeof tabId !== "number") throw new Error("no_active_tab");
  const cap = args?.maxChars ?? READ_CAP;
  if (!Number.isInteger(cap) || cap < 1 || cap > 100000) throw new Error("bad_max_chars");
  const [page] = await browser.tabs.executeScript(tabId, {
    code: `(() => {
      const chars = Array.from(document.body?.innerText ?? '');
      return {url:location.href,title:document.title,
        text:chars.slice(0,${cap}).join(''),chars:chars.length,truncated:chars.length>${cap}};
    })()`,
  });
  if (!page) throw new Error("page_unavailable");
  return {tabId, ...page};
}

async function pageCapture(args) {
  const tabId = args?.tabId;
  if (!Number.isInteger(tabId) || tabId < 0) throw new Error("tab_id_required");
  const before = await browser.tabs.get(tabId);
  const dataUrl = await browser.tabs.captureTab(tabId, {format: "png"});
  const after = await browser.tabs.get(tabId);
  if (before.url !== after.url) throw new Error("tab_navigated_during_capture");
  const prefix = "data:image/png;base64,";
  if (!dataUrl.startsWith(prefix)) throw new Error("capture_is_not_png");
  return {tabId, title: after.title, url: after.url,
    mimeType: "image/png", data: dataUrl.slice(prefix.length)};
}

async function onHostMessage(msg) {
  const reply = { id: msg?.id, ok: false };
  try {
    switch (msg?.verb) {
      case "tabs.list":
        reply.data = await tabsList();
        reply.ok = true;
        break;
      case "page.read":
        reply.data = await pageRead(msg.args);
        reply.ok = true;
        break;
      case "page.capture":
        reply.data = await pageCapture(msg.args);
        reply.ok = true;
        break;
      default:
        reply.error = `unknown_verb:${msg?.verb}`;
    }
  } catch (e) {
    reply.error = String(e?.message ?? e);
  }
  try {
    // Match the OCaml host's inbound frame bound before sending. Oversized
    // captures fail explicitly without disconnecting the user's browser lane.
    if (new TextEncoder().encode(JSON.stringify(reply)).length > 1024 * 1024) {
      delete reply.data;
      reply.ok = false;
      reply.error = "capture_exceeds_native_frame_limit";
    }
    port?.postMessage(reply);
  } catch {
    // Port died mid-answer; the reconnect path owns the next attempt.
  }
}

connect();
