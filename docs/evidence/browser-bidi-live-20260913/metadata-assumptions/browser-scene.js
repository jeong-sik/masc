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
