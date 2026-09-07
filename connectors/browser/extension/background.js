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

async function pageElements(args) {
  const tabId = typeof args?.tabId === "number" ? args.tabId
    : (await browser.tabs.query({active:true,currentWindow:true}))[0]?.id;
  if (!Number.isInteger(tabId) || tabId < 0) throw new Error("invalid_tab_id");
  const [page] = await browser.tabs.executeScript(tabId, {
    code: '(' + (function () {
const nodes = Array.from(document.querySelectorAll('a[href],button,input:not([type=hidden]),textarea,select,[contenteditable=true],[role=button],[role=link]'));
function selector(el) {
  const parts=[];
  for (let node=el; node && node.nodeType===1; node=node.parentElement) {
    const tag=node.localName;
    const siblings=node.parentElement ? Array.from(node.parentElement.children).filter(s=>s.localName===tag) : [node];
    parts.unshift(tag+':nth-of-type('+(siblings.indexOf(node)+1)+')');
  }
  return parts.join(' > ');
}
const visible = nodes.filter(el=>el.getClientRects().length && getComputedStyle(el).visibility!=='hidden');
function observe(el) {
  const result = {selector:selector(el),tag:el.localName,
    role:el.getAttribute('role'),type:el.getAttribute('type'),name:el.getAttribute('aria-label') || el.getAttribute('placeholder') || '',
    text:(el.innerText || '').slice(0,500),href:el.href || null,disabled:el.matches(':disabled')};
  if (el.localName==='input') {
    // Read the normalized DOM type: missing/unknown types behave as text inputs.
    result.type=el.type;
    result.readOnly=!!el.readOnly;
    if (el.type!=='password' && el.type!=='file') result.value=el.value;
    if (el.type==='checkbox' || el.type==='radio') result.checked=!!el.checked;
    if (el.type==='checkbox') result.indeterminate=!!el.indeterminate;
  } else if (el.localName==='textarea') {
    result.value=el.value;
    result.readOnly=!!el.readOnly;
  } else if (el.localName==='select') {
    result.value=el.value;
    result.multiple=!!el.multiple;
    result.options=Array.from(el.options).map(option=>({
      value:option.value,label:option.label,selected:!!option.selected,
      disabled:!!option.disabled || (option.parentElement?.localName==='optgroup' && !!option.parentElement.disabled)
    }));
  }
  return result;
}
return {url:location.href,title:document.title,total:visible.length,truncated:visible.length>200,
  elements:visible.slice(0,200).map(observe)};
}).toString() + ')()'
  });
  if (!page) throw new Error("page_unavailable");
  return {tabId,...page};
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
      case "page.elements":
        reply.data = await pageElements(msg.args);
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
    // Match the native host's bounded incoming frames, including JSON/UTF-8.
    // Reject locally before an oversized frame can disconnect the host.
    if (new TextEncoder().encode(JSON.stringify(reply)).byteLength > 8 * 1024 * 1024) {
      delete reply.data;
      reply.ok = false;
      reply.error = "browser_reply_exceeds_8_mib";
    }
    port?.postMessage(reply);
  } catch {
    // Port died mid-answer; the reconnect path owns the next attempt.
  }
}

connect();
