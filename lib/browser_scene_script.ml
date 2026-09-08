(* Same fixed function as the extension; parity is checked by the Node regression. *)
let runtime = {js|function browserScene(args) {
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
  if (args.mode !== 'read') throw new Error('unknown_scene_mode');
  if (!sameDocument) {
    // getRandomValues also works on ordinary HTTP pages, where randomUUID
    // is unavailable. The document identity carries 128 cryptographic bits.
    const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
      byte => byte.toString(16).padStart(2,'0')).join('');
    state = {document, root:document.documentElement, id, next:0,
      ids:new WeakMap(), nodes:new Map()};
    window[key] = state;
  }
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
  const describe = (kind, element, rawText, rects, extra={}) => {
    if (!rects.length) return;
    if (nodes.length >= nodeLimit || chars >= maxChars) { truncated=true; return; }
    const style=css(element), points=Array.from(rawText);
    const text=points.slice(0,maxChars-chars).join('');
    if (text.length !== rawText.length) truncated=true;
    chars+=Array.from(text).length;
    nodes.push({kind,nodeId:nodeId(element),tag:element.localName,text,rects,
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
|js}

let read = runtime ^ "\nreturn browserScene(arguments[0]);"
