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
  if (typeof tabId !== "number") return { error: "no_active_tab" };
  const [res] = await browser.tabs.executeScript(tabId, {
    code: "document.body ? document.body.innerText : ''",
  });
  const text = String(res ?? "");
  const cap = typeof args?.maxChars === "number" ? args.maxChars : READ_CAP;
  return {
    tabId,
    text: text.length > cap ? text.slice(0, cap) + `\n[TRUNCATED ${text.length} chars]` : text,
    chars: text.length,
  };
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
      default:
        reply.error = `unknown_verb:${msg?.verb}`;
    }
  } catch (e) {
    reply.error = String(e?.message ?? e);
  }
  try {
    port?.postMessage(reply);
  } catch {
    // Port died mid-answer; the reconnect path owns the next attempt.
  }
}

connect();
