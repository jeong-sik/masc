function browserScene(args) {
  const key = Symbol.for('masc.browser.scene.v1');
  let state = window[key];
  const sameDocument = state && state.document === document && state.root === document.documentElement;
  if (args.mode === 'resolve') {
    if (!sameDocument || args.documentId !== state.id) throw new Error('scene_document_changed');
    const ref = state.nodes.get(args.nodeId);
    const element = ref && ref.deref();
    if (!element || !element.isConnected || element.ownerDocument !== document)
      throw new Error('scene_node_detached');
    return element;
  }
  if (args.mode !== 'read' && args.mode !== 'viewport') throw new Error('unknown_scene_mode');
  if (!sameDocument) {
    // getRandomValues also works on ordinary HTTP pages, where randomUUID
    // is unavailable. The document identity carries 128 cryptographic bits.
    const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
      byte => byte.toString(16).padStart(2,'0')).join('');
    state = {document, root:document.documentElement, id, next:0,
      ids:new WeakMap(), nodes:new Map()};
    window[key] = state;
  }
  if (args.mode === 'viewport') return {documentId:state.id,width:innerWidth,height:innerHeight,scrollX,scrollY};
  // Weak references preserve identity through reordering without retaining
  // detached page nodes for the lifetime of a single-page application.
  for (const [id, ref] of state.nodes) if (!ref.deref()?.isConnected) state.nodes.delete(id);
  const nodeId = element => {
    let id = state.ids.get(element);
    if (!id) { id = 'n' + (++state.next); state.ids.set(element,id); }
    state.nodes.set(id,new WeakRef(element));
    return id;
  };
  const maxChars = args.maxChars;
  if (!Number.isSafeInteger(maxChars) || maxChars < 1 || maxChars > 100000)
    throw new Error('invalid_scene_max_chars');
  // A scene has its own 1 MiB JSON/UTF-8 resource ceiling, below the native
  // host's 8 MiB incoming reply bound. Text/node limits alone do not bound
  // page metadata or rectangle arrays; the complete payload is checked below.
  const responseByteLimit = 1024 * 1024;
  const nodeLimit = 200;
  const nodes = [], styles = new WeakMap();
  let chars = 0, truncated = false;
  const css = element => {
    if (!styles.has(element)) styles.set(element,getComputedStyle(element));
    return styles.get(element);
  };
  const rendered = element => {
    for (let parent=element; parent; parent=parent.parentElement) {
      const style=css(parent);
      if (style.display === 'none' || Number(style.opacity) === 0) return false;
    }
    return true;
  };
  const visible = element => rendered(element) && css(element).visibility === 'visible';
  const boxes = rects => Array.from(rects).filter(r =>
    Number.isFinite(r.x) && Number.isFinite(r.y) && r.width > 0 && r.height > 0
    && r.right > 0 && r.bottom > 0 && r.x < innerWidth && r.y < innerHeight)
    .map(r => ({x:r.x,y:r.y,width:r.width,height:r.height}));
  const sourceContext = element => {
    const raw = element.getAttribute('data-masc-source');
    if (raw === null) return null;
    try { return JSON.parse(raw); }
    catch { return {schema:'invalid'}; }
  };
  const describe = (kind, element, rawText, rects, extra={}) => {
    if (!rects.length) return;
    if (nodes.length >= nodeLimit || chars >= maxChars) { truncated=true; return; }
    const style=css(element), points=Array.from(rawText);
    const text=points.slice(0,maxChars-chars).join('');
    if (text.length !== rawText.length) truncated=true;
    chars+=Array.from(text).length;
    nodes.push({kind,nodeId:nodeId(element),tag:element.localName,text,rects,sourceContext:sourceContext(element),
      color:style.color,fontSize:Number.parseFloat(style.fontSize),
      fontWeight:style.fontWeight,whiteSpace:style.whiteSpace,...extra});
  };
  const stack = document.body ? Array.from(document.body.childNodes).reverse() : [];
  while (stack.length && !truncated) {
    const node=stack.pop();
    if (node.nodeType === 3) {
      const element=node.parentElement;
      if (!element || !node.textContent.trim() || !visible(element)) continue;
      const range=document.createRange(); range.selectNodeContents(node);
      describe('text',element,node.textContent,boxes(range.getClientRects()));
      continue;
    }
    if (node.nodeType !== 1 || ['script','style','noscript','template'].includes(node.localName)
        || !rendered(node)) continue;
    const tag=node.localName;
    const control=node.matches('a[href],button,input:not([type=hidden]),textarea,select,[contenteditable=true],[role=button],[role=link]');
    if (control && visible(node)) {
      const label=node.getAttribute('aria-label') || node.getAttribute('placeholder') || node.innerText || tag;
      const input=node instanceof HTMLInputElement, textarea=node instanceof HTMLTextAreaElement;
      const editable=(textarea || (input && ['text','search','email','url','tel','password','number'].includes(node.type)))
        && !node.readOnly && !node.matches(':disabled');
      describe('control',node,label,boxes(node.getClientRects()),{
        controlType:input ? node.type : tag,disabled:node.matches(':disabled'),editable,
        clickable:typeof node.click === 'function' && !node.matches(':disabled')});
      continue;
    }
    if (visible(node) && ['img','svg','canvas','video','iframe','frame'].includes(tag)) {
      describe('raster',node,node.getAttribute('alt') || node.getAttribute('aria-label') || tag,
        boxes(node.getClientRects()));
      continue;
    }
    for (let i=node.childNodes.length-1;i>=0;i--) stack.push(node.childNodes[i]);
  }
  const scene = {schema:'masc.browser.scene.v1',documentId:state.id,url:location.href,title:document.title,
    viewport:{width:innerWidth,height:innerHeight,scrollX,scrollY},nodes,chars,truncated,
    coverage:'top-document DOM geometry; no paint-order, occlusion, pseudo-element or shadow-tree completeness'};
  // Refuse rather than shorten URL/document identity or return partial JSON.
  if (new TextEncoder().encode(JSON.stringify(scene)).byteLength > responseByteLimit)
    throw new Error('scene_response_exceeds_1_mib');
  return scene;
}


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
  if (port) return;
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  const connection = browser.runtime.connectNative(HOST_NAME);
  port = connection;
  connection.onMessage.addListener(msg => onHostMessage(msg, connection));
  connection.onDisconnect.addListener(() => {
    if (port !== connection) return;
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
    runAt: "document_end",
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
    runAt: "document_end",
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

async function pageScene(args) {
  if (!Number.isSafeInteger(args?.tabId) || args.tabId < 0) throw new Error('tab_id_required');
  const [scene] = await browser.tabs.executeScript(args.tabId, {
    runAt: "document_end",
    code: '(' + browserScene.toString() + ')(' + JSON.stringify({mode:'read',maxChars:args.maxChars}) + ')',
  });
  if (!scene) throw new Error('scene_unavailable');
  return {tabId:args.tabId,...scene};
}

async function pageCapture(args) {
  const tabId = args?.tabId;
  if (!Number.isInteger(tabId) || tabId < 0) throw new Error("tab_id_required");
  const before = await browser.tabs.get(tabId);
  const observeViewport = async () => {
    const [value] = await browser.tabs.executeScript(tabId, {
    runAt: "document_end",
      code:'(' + browserScene.toString() + ')({mode:"viewport"})'
    });
    if (!value) throw new Error('viewport_unavailable');
    return value;
  };
  const viewport = await observeViewport();
  const dataUrl = await browser.tabs.captureTab(tabId, {format: "png"});
  const after = await browser.tabs.get(tabId);
  const afterViewport = await observeViewport();
  if (before.url !== after.url || Object.keys(viewport).some(key => viewport[key] !== afterViewport[key]))
    throw new Error("viewport_changed_during_capture");
  const prefix = "data:image/png;base64,";
  if (!dataUrl.startsWith(prefix)) throw new Error("capture_is_not_png");
  return {tabId, title: after.title, url: after.url,
    mimeType: "image/png", data: dataUrl.slice(prefix.length), viewport};
}

function interactInPage(args) {
  if (args.expectedUrl !== undefined && args.expectedUrl !== location.href)
    throw new Error("page_url_changed");
  const before = location.href;
  if (args.action === "drag") throw new Error("trusted_drag_requires_automation");
  if (args.action === "click_at") {
    const current = browserScene({mode:'viewport'}), expected = args.viewport;
    if (!expected || Object.keys(current).some(key => current[key] !== expected[key]))
      throw new Error('observed_viewport_changed');
    const point = args.point;
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)
        || point.x < 0 || point.x >= 1 || point.y < 0 || point.y >= 1)
      throw new Error('invalid_viewport_point');
    const element = document.elementFromPoint(point.x * innerWidth, point.y * innerHeight);
    if (!element || typeof element.click !== 'function') throw new Error('point_has_no_clickable_element');
    if (element.matches(':disabled')) throw new Error('element_disabled');
    element.click();
  } else if (args.action === "scroll") {
    if (!Number.isSafeInteger(args.x) || !Number.isSafeInteger(args.y))
      throw new Error("scroll_coordinates_must_be_integers");
    window.scrollBy({left: args.x, top: args.y, behavior: "instant"});
  } else if (args.action === "click" || args.action === "fill") {
    let element;
    if (args.nodeId !== undefined || args.documentId !== undefined) {
      if (args.selector !== undefined || typeof args.nodeId !== "string" || typeof args.documentId !== "string")
        throw new Error("invalid_scene_reference");
      element = browserScene({...args,mode:'resolve'});
    } else {
      if (typeof args.selector !== "string" || !args.selector.trim()) throw new Error("selector_required");
      let elements;
      try { elements = document.querySelectorAll(args.selector); }
      catch { throw new Error("invalid_css_selector"); }
      if (elements.length !== 1)
        throw new Error(elements.length === 0 ? "element_not_found" : "selector_is_ambiguous");
      element = elements[0];
    }
    const style = getComputedStyle(element);
    if (!element.getClientRects().length || style.visibility === "hidden" || style.display === "none")
      throw new Error("element_not_visible");
    if (element.matches(":disabled")) throw new Error("element_disabled");
    if (args.action === "click") {
      if (typeof element.click !== "function") throw new Error("element_not_clickable");
      element.click();
    } else {
      if (typeof args.text !== "string") throw new Error("fill_text_required");
      const input = element instanceof HTMLInputElement;
      const textarea = element instanceof HTMLTextAreaElement;
      if ((!input && !textarea) || (input && !["text", "search", "email", "url", "tel", "password", "number"].includes(element.type)))
        throw new Error("element_is_not_a_text_input");
      if (element.readOnly) throw new Error("element_read_only");
      const prototype = input ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, "value").set;
      const previousValue = element.value;
      setter.call(element, args.text);
      if (element.value !== args.text) {
        setter.call(element, previousValue);
        throw new Error("input_rejected_value");
      }
      element.dispatchEvent(new Event("input", {bubbles: true}));
      element.dispatchEvent(new Event("change", {bubbles: true}));
      if (element.value !== args.text) throw new Error("input_changed_during_events");
    }
  } else throw new Error("unknown_interaction_action");
  return {action: args.action, urlBefore: before, url: location.href,
    title: document.title, scrollX: window.scrollX, scrollY: window.scrollY};
}


async function pageInteract(args) {
  if (!Number.isSafeInteger(args?.tabId) || args.tabId < 0) throw new Error("tab_id_required");
  if (!['click', 'fill', 'scroll', 'click_at', 'drag'].includes(args.action)) throw new Error("unknown_interaction_action");
  // JSON encoding keeps selectors and text out of executable source syntax.
  const [result] = await browser.tabs.executeScript(args.tabId, {
    runAt: "document_end",
    code: `(() => { const browserScene = ${browserScene.toString()}; return (${interactInPage.toString()})(${JSON.stringify(args)}); })()`,
  });
  if (!result) throw new Error("page_unavailable");
  return {tabId: args.tabId, ...result};
}

async function onHostMessage(msg, connection = port) {
  const reply = { id: msg?.id, ok: false };
  try {
    switch (msg?.verb) {
      case "browser.info":
        reply.data = await browser.runtime.getBrowserInfo();
        reply.ok = true;
        break;
      case "tabs.list":
        reply.data = await tabsList();
        reply.ok = true;
        break;
      case "page.scene":
        reply.data = await pageScene(msg.args);
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
      case "page.interact":
        reply.data = await pageInteract(msg.args);
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
    connection?.postMessage(reply);
  } catch {
    // Port died mid-answer; the reconnect path owns the next attempt.
  }
}

connect();
