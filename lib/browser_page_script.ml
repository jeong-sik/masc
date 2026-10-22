(* Fixed observation script shared by the native Firefox reader's callers.
   Selectors are generated from the observed DOM, never inferred from text. *)

(* A text read: the page's visible text up to [arguments[0]] Unicode code
   points, with its full length so a reader knows what was cut. *)
let text =
  "const text=document.body?.innerText ?? ''; const chars=Array.from(text); return {url:location.href,title:document.title,text:chars.slice(0,arguments[0]).join(''),chars:chars.length,truncated:chars.length>arguments[0]};"

(* What a text read returns when it names no cap, and the most it returns. *)
let default_text_chars = 50_000
let max_text_chars = 100_000

let text_cap_refused = Printf.sprintf "maxChars must be between 1 and %d" max_text_chars

let text_cap requested =
  let cap = match requested with Some cap -> cap | None -> default_text_chars in
  if cap < 1 || cap > max_text_chars then Error text_cap_refused else Ok cap
;;

let elements = {|
// WAI-ARIA 1.2 roles are ordered fallbacks, not simultaneous declarations.
// https://www.w3.org/TR/wai-aria-1.2/#roles
const ariaRoles = new Set('alert alertdialog application article banner blockquote button caption cell checkbox code columnheader combobox complementary contentinfo definition deletion dialog directory document emphasis feed figure form generic grid gridcell group heading img insertion link list listbox listitem log main marquee math menu menubar menuitem menuitemcheckbox menuitemradio meter navigation none note option paragraph presentation progressbar radio radiogroup region row rowgroup rowheader scrollbar search searchbox separator slider spinbutton status strong subscript suggestion superscript switch tab table tablist tabpanel term textbox time timer toolbar tooltip tree treegrid treeitem'.split(' '));
const effectiveRole = element => (element.getAttribute('role') || '').split(/\s+/)
  .find(role => ariaRoles.has(role)) || null;
const actionRoles = new Set('button link checkbox radio switch menuitem menuitemcheckbox menuitemradio tab option combobox'.split(' '));
// [within] is a CSS selector read by the page's own engine: only controls that
// match it, or sit inside an element that matches it, are observed. An invalid
// selector is refused rather than read as the whole page.
const within = (arguments[0] || {}).within;
let withinMatches = null;
if (within !== undefined) {
  try { withinMatches = document.querySelectorAll(within).length; }
  catch { throw new Error('invalid_css_selector'); }
}
const nodes = Array.from(document.querySelectorAll('a[href],button,input:not([type=hidden]),textarea,select,summary,label,[contenteditable=true],[onclick],[role~=button],[role~=link],[role~=checkbox],[role~=radio],[role~=switch],[role~=menuitem],[role~=menuitemcheckbox],[role~=menuitemradio],[role~=tab],[role~=option],[role~=combobox]'))
  .filter(el => within === undefined || el.closest(within) !== null);
// A single synchronous observation shares styles and ancestor visibility.
// Large feeds have many controls under the same ancestors; walking and
// restyling that chain for every control repeats the same work.
const styles = new WeakMap(), displayedAncestors = new WeakMap();
const styleOf = element => {
  if (!styles.has(element)) styles.set(element, getComputedStyle(element));
  return styles.get(element);
};
const displayed = element => {
  const pending = [];
  let node = element;
  while (node && !displayedAncestors.has(node)) {
    const style = styleOf(node);
    if (style.display === 'none' || Number(style.opacity) === 0) {
      displayedAncestors.set(node, false);
      break;
    }
    pending.push(node);
    node = node.parentElement;
  }
  const result = node === null || displayedAncestors.get(node);
  for (const ancestor of pending) displayedAncestors.set(ancestor, result);
  return result;
};
function selector(el) {
  const parts=[];
  for (let node=el; node && node.nodeType===1; node=node.parentElement) {
    const tag=node.localName;
    const siblings=node.parentElement ? Array.from(node.parentElement.children).filter(s=>s.localName===tag) : [node];
    parts.unshift(tag+':nth-of-type('+(siblings.indexOf(node)+1)+')');
  }
  return parts.join(' > ');
}
const labelTextRects = (element, admit = rects => Array.from(rects)) => {
  if (element.localName !== 'label') return [];
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT), rects = [];
  while (walker.nextNode()) {
    const text = walker.currentNode, parent = text.parentElement;
    if (!text.textContent.trim() || !parent || styleOf(parent).visibility !== 'visible'
        || !displayed(parent)) continue;
    const range = document.createRange(); range.selectNodeContents(text);
    rects.push(...admit(range.getClientRects(), parent).filter(r => r.width > 0 && r.height > 0));
  }
  return rects;
};
const observable = el => (el.getClientRects().length || labelTextRects(el).length)
  && styleOf(el).visibility !== 'hidden' && styleOf(el).visibility !== 'collapse'
  && displayed(el);
const visible = nodes.filter(el=>observable(el)
  && (!el.getAttribute('role') || actionRoles.has(effectiveRole(el))
    || ['a','button','input','textarea','select','summary','label'].includes(el.localName)
    || el.getAttribute('onclick') !== null || el.getAttribute('contenteditable') === 'true')
  && (el.localName!=='label' || el.hasAttribute('onclick') || actionRoles.has(effectiveRole(el))
    || (el.control?.localName==='input' && ['checkbox','radio'].includes(el.control.type) && !observable(el.control))));
function disabled(el) {
  const target=(el.localName==='label' && el.control) || el;
  if (target.matches(':disabled')) return true;
  for (const start of new Set([el,target]))
    for (let parent=start;parent;parent=parent.parentElement)
    if (parent.getAttribute('aria-disabled')==='true') return true;
  return false;
}
function name(el) {
  const labelledBy=(el.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean)
    .map(id=>document.getElementById(id)?.textContent || '').join(' ').trim();
  const labels=Array.from(el.labels || []).map(label=>label.innerText || '').filter(Boolean).join(' ');
  return el.getAttribute('aria-label') || labelledBy || labels || el.getAttribute('placeholder') || '';
}
// The first [points] characters of [text]. A character is at most two UTF-16
// units, so only that much of a long text is split into characters, and the
// cut never leaves half of one.
const head = (text, points) => Array.from(text.slice(0, points * 2)).slice(0, points).join('');
function observe(el) {
  const result = {selector:selector(el),tag:el.localName,
    role:effectiveRole(el),type:el.getAttribute('type'),name:name(el),
    text:head(el.innerText || '', 500),href:el.href || null,disabled:disabled(el)};
  const target=(el.localName==='label' && el.control) || el;
  if (target.localName==='input' && ['checkbox','radio'].includes(target.type))
    result.checked=!!target.checked;
  if (target.localName==='input' && target.type==='checkbox') result.indeterminate=!!target.indeterminate;
  const checkedRole=effectiveRole(el), checked=el.getAttribute('aria-checked');
  if (['checkbox','menuitemcheckbox','radio','menuitemradio','switch'].includes(checkedRole)
      && ['true','false','mixed'].includes(checked))
    result.ariaChecked=checked==='mixed' && !['checkbox','menuitemcheckbox'].includes(checkedRole) ? 'false' : checked;
  if (['tab','option','row','treeitem','gridcell'].includes(effectiveRole(el))
      && ['true','false'].includes(el.getAttribute('aria-selected')))
    result.ariaSelected=el.getAttribute('aria-selected');
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
return {url:location.href,title:document.title,
  ...(within === undefined ? {} : {within,withinMatches}),
  total:visible.length,truncated:visible.length>200,
  elements:visible.slice(0,200).map(observe)};
|}

(* The argument object [elements] reads. An empty selector would match
   nothing in the page and is refused here; any other text goes to the
   page's CSS engine, which decides whether it is a selector. *)
let within_of_json = function
  | None -> Ok None
  | Some (`String "") -> Error "within must be a non-empty CSS selector"
  | Some (`String selector) -> Ok (Some selector)
  | Some _ -> Error "within must be a CSS selector string"
;;

let elements_args within =
  `Assoc (Option.to_list (Option.map (fun selector -> "within", `String selector) within))
;;

(* A browser-lane extension built before [within] ignores it and answers with
   every control, which would read as a scoped answer. The page's own
   [withinMatches] count is the proof that the scope was applied. *)
let scoped_elements_refused =
  "the connected browser answered without applying within; its browser-lane extension \
   predates within, so update it or read without within"

let check_scoped_elements ~within reply =
  match within, reply with
  | None, _ -> Ok reply
  | Some _, `Assoc fields ->
    (match List.assoc_opt "withinMatches" fields with
     | Some (`Int _) -> Ok reply
     | Some _ | None -> Error scoped_elements_refused)
  | Some _, _ -> Error scoped_elements_refused
;;

let frames = {|
function selector(el) {
  const parts=[];
  for (let node=el; node && node.nodeType===1; node=node.parentElement) {
    const tag=node.localName;
    const siblings=node.parentElement ? Array.from(node.parentElement.children).filter(s=>s.localName===tag) : [node];
    parts.unshift(tag+':nth-of-type('+(siblings.indexOf(node)+1)+')');
  }
  return parts.join(' > ');
}
const frames=Array.from(document.querySelectorAll('iframe,frame'));
return {url:location.href,title:document.title,frames:frames.map(el=>({selector:selector(el),name:el.name || '',title:el.title || '',src:el.src || ''}))};
|}
