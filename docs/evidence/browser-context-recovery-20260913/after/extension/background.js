function browserScene(args) {
  const linkHref = element => {
    if (element.localName !== 'a') return null;
    const value = element.href;
    const raw = typeof value === 'string' ? value : value?.baseVal;
    // XLink is the SVG spelling of href and only an SVG anchor is followed
    // through it. An HTML anchor carrying only an xlink:href has an empty
    // .href, and resolving "" against baseURI advertised the current page as
    // the destination -- selecting that control reloaded the page instead of
    // following the XLink value.
    const xlink = typeof SVGAElement !== 'undefined' && element instanceof SVGAElement
      && element.hasAttributeNS?.('http://www.w3.org/1999/xlink','href');
    if (typeof raw !== 'string' || !(element.hasAttribute('href') || xlink)) return null;
    try { return new URL(raw,element.baseURI || document.baseURI).href; }
    catch { return null; }
  };
  const key = Symbol.for('masc.browser.scene.refs.v3');
  let state = window[key];
  const sameDocument = state && state.document === document && state.root === document.documentElement;
  if (args.mode === 'resolve' || args.mode === 'resolve_link') {
    if (!sameDocument || args.documentId !== state.id) throw new Error('scene_document_changed');
    const ref = state.nodes.get(args.nodeId);
    const element = ref && ref.deref();
    if (!element || !element.isConnected || element.ownerDocument !== document)
      throw new Error('scene_node_detached');
    if (args.mode === 'resolve_link') {
      if (!state.links.has(args.nodeId)) throw new Error('scene_link_not_observed');
      if (linkHref(element) !== state.links.get(args.nodeId)) throw new Error('scene_link_destination_changed');
    }
    return element;
  }
  if (args.mode !== 'read' && args.mode !== 'viewport') throw new Error('unknown_scene_mode');
  if (!sameDocument) {
    // getRandomValues also works on ordinary HTTP pages, where randomUUID
    // is unavailable. The document identity carries 128 cryptographic bits.
    const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
      byte => byte.toString(16).padStart(2,'0')).join('');
    state = {document, root:document.documentElement, id, next:0,
      ids:new WeakMap(), nodes:new Map(), links:new Map()};
    window[key] = state;
  }
  if (args.mode === 'viewport') return {documentId:state.id,width:innerWidth,height:innerHeight,scrollX,scrollY};
  // Weak references preserve identity through reordering without retaining
  // detached page nodes for the lifetime of a single-page application.
  for (const [id, ref] of state.nodes) if (!ref.deref()?.isConnected) {
    state.nodes.delete(id); state.links.delete(id);
  }
  const nodeId = element => {
    let id = state.ids.get(element);
    const href = linkHref(element);
    // A recycled anchor gets a new observation reference. Retire its old
    // reference so connected virtualized anchors cannot accumulate revisions.
    if (!id || (href !== null && state.links.get(id) !== href)) {
      if (id) { state.nodes.delete(id); state.links.delete(id); }
      id = 'n' + (++state.next); state.ids.set(element,id);
      if (href !== null) state.links.set(id,href);
    }
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
  const boxes = (rects, element) => {
    let left=0,top=0,right=innerWidth,bottom=innerHeight;
    for (let ancestor=element; ancestor; ancestor=ancestor.parentElement) {
      const style=css(ancestor);
      const clipsX=['auto','scroll','hidden','clip'].includes(style.overflowX);
      const clipsY=['auto','scroll','hidden','clip'].includes(style.overflowY);
      if (clipsX || clipsY) {
        const r=ancestor.getBoundingClientRect();
        if (clipsX) {left=Math.max(left,r.left);right=Math.min(right,r.right);}
        if (clipsY) {top=Math.max(top,r.top);bottom=Math.min(bottom,r.bottom);}
      }
      // Positioned descendants can escape overflow ancestors before their
      // containing block. We do not reconstruct CSS containing blocks here:
      // retain uncertain geometry instead of hiding a visible popup. This
      // can include positioned content clipped by a transformed ancestor.
      if (style.position === 'fixed' || style.position === 'absolute') break;
    }
    return Array.from(rects).filter(r => Number.isFinite(r.x) && Number.isFinite(r.y))
      .map(r => ({x:Math.max(left,r.x),y:Math.max(top,r.y),
        width:Math.min(right,r.right)-Math.max(left,r.x),
        height:Math.min(bottom,r.bottom)-Math.max(top,r.y)}))
      .filter(r => r.width>0 && r.height>0);
  };
  const svgVisibleText = element => {
    if (element.namespaceURI !== 'http://www.w3.org/2000/svg') return '';
    const pending=Array.from(element.childNodes).reverse(), parts=[];
    while (pending.length) {
      const child=pending.pop();
      if (child.nodeType === 3) {
        const parent=child.parentElement;
        if (!parent || !child.textContent || !visible(parent)) continue;
        const range=document.createRange(); range.selectNodeContents(child);
        if (boxes(range.getClientRects(),parent).length) parts.push(child.textContent);
      } else if (child.nodeType === 1 && rendered(child)) {
        for (let i=child.childNodes.length-1;i>=0;i--) pending.push(child.childNodes[i]);
      }
    }
    return parts.join('').trim();
  };
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
  const root = args.scope ? browserScene({...args.scope,mode:'resolve'}) : document.body;
  const view = args.view === undefined ? 'content' : args.view;
  if (view !== 'content' && view !== 'regions') throw new Error('unknown_scene_view');
  if (view === 'regions' && root) {
    const selector = 'main,nav,aside,section,article,header,footer,search,form[aria-label],form[aria-labelledby],[role~=main],[role~=navigation],[role~=complementary],[role~=region],[role~=log],[role~=banner],[role~=contentinfo],[role~=search],[role~=form]';
    const regions = [...(root.matches(selector) ? [root] : []),...root.querySelectorAll(selector)];
    for (const region of regions) {
      if (truncated) break;
      if (!visible(region)) continue;
      const role = region.getAttribute('role') || region.localName;
      const labelledBy = (region.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean)
        .map(id => document.getElementById(id)?.textContent || '').join(' ').trim();
      const heading = region.querySelector('h1,h2,h3,h4,h5,h6,[role=heading]');
      const name = region.getAttribute('aria-label') || labelledBy || heading?.textContent || role;
      describe('region',region,name,boxes(region.getClientRects(),region),{role});
    }
  }
  // Landmarks and scrollable panes are independent observed properties.
  // A site instruction chooses the relevant scope; a header must not hide
  // an unrelated message pane from the observation.
  if (view === 'regions' && root && !truncated) {
    for (const element of [root,...root.querySelectorAll('*')]) {
      if (truncated) break;
      if (!visible(element)) continue;
      const style = css(element);
      const scrollsY = ['auto','scroll'].includes(style.overflowY)
        && element.scrollHeight > element.clientHeight;
      const scrollsX = ['auto','scroll'].includes(style.overflowX)
        && element.scrollWidth > element.clientWidth;
      if (!scrollsY && !scrollsX) continue;
      const rects = boxes(element.getClientRects(),element);
      if (!rects.length) continue;
      const heading = element.querySelector('h1,h2,h3,h4,h5,h6,[role=heading]');
      const name = element.getAttribute('aria-label') || heading?.textContent
        || (scrollsY ? 'Vertical scroll area' : 'Horizontal scroll area');
      // The same element may already be a landmark: keep one reference.
      const existing = nodes.find(node => node.nodeId === state.ids.get(element));
      if (!existing) describe('region',element,name,rects,{role:'scroll-area'});
    }
  }
  const stack = root && view === 'content' ? Array.from(root.childNodes).reverse() : [];
  while (stack.length && !truncated) {
    const node=stack.pop();
    if (node.nodeType === 3) {
      const element=node.parentElement;
      if (!element || !node.textContent.trim() || !visible(element)) continue;
      const range=document.createRange(); range.selectNodeContents(node);
      describe('text',element,node.textContent,boxes(range.getClientRects(),element));
      continue;
    }
    if (node.nodeType !== 1 || ['script','style','noscript','template'].includes(node.localName)
        || !rendered(node)) continue;
    const tag=node.localName;
    const control=linkHref(node) !== null || node.matches('button,input:not([type=hidden]),textarea,select,[contenteditable=true],[role=button],[role=link]');
    if (control && visible(node)) {
      const label=node.getAttribute('aria-label') || node.getAttribute('placeholder') || node.innerText || svgVisibleText(node) || tag;
      const input=node instanceof HTMLInputElement, textarea=node instanceof HTMLTextAreaElement;
      const editable=(textarea || (input && ['text','search','email','url','tel','password','number'].includes(node.type)))
        && !node.readOnly && !node.matches(':disabled');
      describe('control',node,label,boxes(node.getClientRects(),node),{
        ...(linkHref(node) !== null ? {href:linkHref(node)} : {}),
        controlType:input ? node.type : tag,disabled:node.matches(':disabled'),editable,
        clickable:typeof node.click === 'function' && !node.matches(':disabled')});
      continue;
    }
    if (visible(node) && ['img','svg','canvas','video','iframe','frame'].includes(tag)) {
      describe('raster',node,node.getAttribute('alt') || node.getAttribute('aria-label') || tag,
        boxes(node.getClientRects(),node));
      if (tag === 'svg') for (const anchor of Array.from(node.querySelectorAll('a')).reverse())
        if (linkHref(anchor) !== null) stack.push(anchor);
      continue;
    }
    for (let i=node.childNodes.length-1;i>=0;i--) stack.push(node.childNodes[i]);
  }
  const scene = {schema:'masc.browser.scene.v1',documentId:state.id,url:location.href,title:document.title,
    viewport:{width:innerWidth,height:innerHeight,scrollX,scrollY},nodes,chars,truncated,
    scope:args.scope || null,view,
    coverage:'top-document DOM geometry; no paint-order, occlusion, pseudo-element or shadow-tree completeness'};
  // Refuse rather than shorten URL/document identity or return partial JSON.
  if (new TextEncoder().encode(JSON.stringify(scene)).byteLength > responseByteLimit)
    throw new Error('scene_response_exceeds_1_mib');
  return scene;
}


function browserDocument() {
  if (window !== window.top) throw new Error('document_observation_requires_top_document');
  const identity = browserScene({mode:'viewport'});
  const page = {documentId:identity.documentId,url:location.href,title:document.title,
    observedAt:Date.now()/1000,html:document.documentElement?.outerHTML ?? null,
    htmlComplete:document.documentElement !== null,htmlUnavailableReason:null};
  // The observation is optional. Keep identity and report incomplete coverage
  // rather than returning a truncated document as if it were complete HTML.
  if (page.html === null) {
    page.htmlComplete = false;
    page.htmlUnavailableReason = 'document_has_no_root';
  } else if (new TextEncoder().encode(JSON.stringify(page)).byteLength > 1024 * 1024) {
    page.html = null;
    page.htmlComplete = false;
    page.htmlUnavailableReason = 'document_html_exceeds_1_mib';
  }
  return page;
}

// masc browser lane — background bridge (B backend).
//
// One native-messaging port to the host process. The host asks, this side
// answers; nothing is pushed proactively. Verbs are a closed set: an unknown
// verb is refused by name, never guessed (the same rule the lane protocol
// holds everywhere).

const HOST_NAME = "masc_browser_proof_9d74632c82214036bf05685fa74d2907";
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
  if (args?.includeHtml === true) {
    if (!Number.isSafeInteger(args.tabId) || args.tabId < 0) throw new Error("tab_id_required");
    const [page] = await browser.tabs.executeScript(args.tabId, {
      runAt: "document_end",
      code: browserScene.toString() + "\n" + browserDocument.toString() + "\nbrowserDocument();",
    });
    if (!page) throw new Error("page_unavailable");
    return {tabId:args.tabId,...page};
  }
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
    code: '(' + browserScene.toString() + ')(' + JSON.stringify({mode:'read',maxChars:args.maxChars,view:args.view,scope:args.scope}) + ')',
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
  let effectStarted = false;
  try {
  if (args.expectedUrl !== undefined && args.expectedUrl !== location.href)
    throw new Error("page_url_changed");
  const before = location.href;
  // The same predicate the scene admits a control by (browser_scene_script.ml
  // `rendered`/`visible`). display and opacity take effect through ancestors,
  // so a page that withdrew the target by setting opacity 0 on a wrapper
  // leaves an element that still reports client rects and its own computed
  // display. Checking only the element acted on a link the read surface had
  // already stopped showing.
  const observable = element => {
    if (!element.getClientRects().length) return false;
    if (getComputedStyle(element).visibility !== 'visible') return false;
    for (let node = element; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === 'none' || Number(style.opacity) === 0) return false;
    }
    return true;
  };
  if (args.action === "follow_link") {
    const element = browserScene({...args,mode:'resolve_link'});
    if (!(element instanceof HTMLAnchorElement) && !(typeof SVGAElement !== 'undefined' && element instanceof SVGAElement))
      throw new Error('follow_link_requires_anchor');
    if (!observable(element)) throw new Error('element_not_visible');
    const target = element.getAttribute('target') ?? document.querySelector('base[target]')?.getAttribute('target') ?? '';
    const normalizedTarget = target.toLowerCase();
    const sameTab = normalizedTarget === '' || normalizedTarget === '_self'
      || (window === window.top && (normalizedTarget === '_top' || normalizedTarget === '_parent'));
    if (!sameTab) throw new Error('follow_link_requires_same_tab');
    const rel = (element.getAttribute('rel') || '').toLowerCase().split(/\s+/);
    if (rel.includes('noreferrer') || element.hasAttribute('referrerpolicy'))
      throw new Error('follow_link_referrer_policy_unsupported');
    if (element.hasAttribute('download')) throw new Error('follow_link_rejects_download');
    const rawHref = typeof element.href === 'string' ? element.href : element.href.baseVal;
    const destination = new URL(rawHref, element.baseURI || document.baseURI || location.href);
    if (!['http:','https:'].includes(destination.protocol)) throw new Error('follow_link_requires_http_url');
    const result = {action:args.action,urlBefore:before,url:before,destinationUrl:destination.href,
      navigationSource:{url:before,documentId:args.documentId},
      title:document.title,scrollX:scrollX,scrollY:scrollY};
    // Follow the observed href directly: page click handlers cannot redirect
    // this primitive into window.open or an unrelated application action.
    effectStarted = true;
    location.assign(destination.href);
    return result;
  }
  if (args.action === "drag") throw new Error("trusted_drag_requires_automation");
  if (args.action === "click_at" || args.action === "scroll_at") {
    const current = browserScene({mode:'viewport'}), expected = args.viewport;
    if (!expected || Object.keys(current).some(key => current[key] !== expected[key]))
      throw new Error('observed_viewport_changed');
    const point = args.point;
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)
        || point.x < 0 || point.x >= 1 || point.y < 0 || point.y >= 1)
      throw new Error('invalid_viewport_point');
    let element = document.elementFromPoint(point.x * innerWidth, point.y * innerHeight);
    if (!element) throw new Error('point_has_no_element');
    if (args.action === 'click_at') {
      if (typeof element.click !== 'function') throw new Error('point_has_no_clickable_element');
      if (element.matches(':disabled')) throw new Error('element_disabled');
    effectStarted = true;
      element.click();
    } else {
      if (!Number.isSafeInteger(args.x) || !Number.isSafeInteger(args.y))
        throw new Error('scroll_coordinates_must_be_integers');
      // Hit testing stops at shadow hosts and frame elements. Resolve both
      // before scrolling; never redirect an inaccessible frame hit to its page.
      let hitWindow = window, hitX = point.x * innerWidth, hitY = point.y * innerHeight;
      for (;;) {
        if (element.shadowRoot && typeof element.shadowRoot.elementFromPoint === 'function') {
          const inner = element.shadowRoot.elementFromPoint(hitX, hitY);
          if (inner && inner !== element) { element = inner; continue; }
        }
        if (element.localName !== 'iframe' && element.localName !== 'frame') break;
        let childDocument;
        try { childDocument = element.contentDocument; }
        catch { throw new Error('scroll_frame_inaccessible'); }
        if (!childDocument || !childDocument.defaultView) throw new Error('scroll_frame_inaccessible');
        // A bounding rectangle cannot invert rotation, skew or perspective.
        // Reject transformed frames/ancestors before either scroll axis acts.
        for (let node = element; node; node = node.parentElement || node.getRootNode().host) {
          const style = hitWindow.getComputedStyle(node);
          if (style.transform !== 'none' || style.perspective !== 'none'
              || (style.rotate && style.rotate !== 'none')
              || (style.scale && style.scale !== 'none')
              || (style.translate && style.translate !== 'none')
              || (style.zoom && style.zoom !== 'normal' && Number(style.zoom) !== 1))
            throw new Error('scroll_frame_geometry_unsupported');
        }
        const rect = element.getBoundingClientRect(), style = hitWindow.getComputedStyle(element);
        hitX -= rect.left + element.clientLeft + Number.parseFloat(style.paddingLeft);
        hitY -= rect.top + element.clientTop + Number.parseFloat(style.paddingTop);
        hitWindow = childDocument.defaultView;
        if (hitX < 0 || hitY < 0 || hitX >= hitWindow.innerWidth || hitY >= hitWindow.innerHeight)
          throw new Error('scroll_point_outside_frame_content');
        element = childDocument.elementFromPoint(hitX, hitY);
        if (!element) throw new Error('point_has_no_element');
      }
      // Follow actual scroll containers under the pointer. Slack's message
      // pane scrolls independently of document.body and its channel sidebar.
      const scrollAxis = (delta, axis) => {
        if (delta === 0) return;
        const vertical = axis === 'y';
        for (let node = element; node; node = node.parentElement || node.getRootNode().host) {
          const style = hitWindow.getComputedStyle(node);
          const overflow = vertical ? style.overflowY : style.overflowX;
          const position = vertical ? node.scrollTop : node.scrollLeft;
          const maximum = vertical ? node.scrollHeight-node.clientHeight : node.scrollWidth-node.clientWidth;
          if ((overflow === 'auto' || overflow === 'scroll') && maximum > 0) {
            node.scrollBy({left:vertical ? 0 : delta,top:vertical ? delta : 0,behavior:'instant'});
            const after = vertical ? node.scrollTop : node.scrollLeft;
            // Reverse-flow chat and RTL scrollers may have negative positions.
            // The browser's actual movement establishes consumption, not a range guess.
            if (after !== position) return;
            const chain = vertical ? style.overscrollBehaviorY : style.overscrollBehaviorX;
            if (chain === 'contain' || chain === 'none') return;
          }
        }
        hitWindow.scrollBy({left:vertical ? 0 : delta,top:vertical ? delta : 0,behavior:'instant'});
      };
    effectStarted = true;
      scrollAxis(args.x,'x'); scrollAxis(args.y,'y');
    }
  } else if (args.action === "scroll") {
    if (!Number.isSafeInteger(args.x) || !Number.isSafeInteger(args.y))
      throw new Error("scroll_coordinates_must_be_integers");
    effectStarted = true;
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
    if (!observable(element)) throw new Error("element_not_visible");
    if (element.matches(":disabled")) throw new Error("element_disabled");
    if (args.action === "click") {
      if (typeof element.click !== "function") throw new Error("element_not_clickable");
    effectStarted = true;
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
    effectStarted = true;
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
  } catch (error) {
    return {interactionFailure:{message:String(error?.message ?? error),effectStarted}};
  }
}


async function pageInteract(args) {
  if (args?.action === 'activate_tab') {
    let effectStarted = false;
    try {
      if (!Number.isSafeInteger(args.tabId) || args.tabId < 0) throw new Error('tab_id_required');
      if (typeof args.expectedUrl !== 'string' || !args.expectedUrl.trim()) throw new Error('activate_tab_requires_expected_url');
      const before = await browser.tabs.get(args.tabId);
      if (before.url !== args.expectedUrl) throw new Error('page_url_changed');
      effectStarted = true;
      await browser.tabs.update(args.tabId, {active:true});
      const after = await browser.tabs.get(args.tabId);
      if (after.id !== args.tabId || after.url !== args.expectedUrl || !after.active)
        throw new Error('activated_tab_observation_changed');
      return {tabId:args.tabId,action:'activate_tab',urlBefore:before.url,url:after.url,active:after.active,title:after.title};
    } catch (cause) {
      const error = new Error(String(cause?.message ?? cause));
      error.effectStarted = effectStarted;
      throw error;
    }
  }
  // Only this read-only preflight can establish that injection never began.
  // A later executeScript rejection can lose a result after a page effect.
  try {
    if (!Number.isSafeInteger(args?.tabId) || args.tabId < 0) throw new Error("tab_id_required");
    if (!['click', 'follow_link', 'fill', 'scroll', 'click_at', 'scroll_at', 'drag'].includes(args.action)) throw new Error("unknown_interaction_action");
    const tab = await browser.tabs.get(args.tabId);
    if (args.expectedUrl !== undefined && tab.url !== args.expectedUrl) throw new Error('page_url_changed');
  } catch (cause) {
    const error = new Error(String(cause?.message ?? cause));
    error.effectStarted = false;
    throw error;
  }
  // JSON encoding keeps selectors and text out of executable source syntax.
  const [result] = await browser.tabs.executeScript(args.tabId, {
    runAt: "document_end",
    code: `(() => { const browserScene = ${browserScene.toString()}; return (${interactInPage.toString()})(${JSON.stringify(args)}); })()`,
  });
  if (!result) throw new Error("page_unavailable");
  if (result.interactionFailure) {
    const error = new Error(result.interactionFailure.message);
    error.effectStarted = result.interactionFailure.effectStarted;
    throw error;
  }
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
    if (msg?.verb === 'page.interact' && e?.effectStarted === false)
      reply.effectPhase = 'not_started';
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
