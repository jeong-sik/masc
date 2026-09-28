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
|}

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
