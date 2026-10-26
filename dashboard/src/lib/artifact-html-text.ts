import { defaultTreeAdapter as tree, html, parse, serialize, serializeOuter, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { decodeHTML } from 'entities'

export type ArtifactHtmlText = { id: number; start: number; end: number; raw: string; text: string }
export type ArtifactHtmlEditor = { document: string; token: string; parts: readonly ArtifactHtmlText[] }
const marker = 'data-masc-artifact-text'
const removed = new Set(['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'base', 'meta', 'link'])
const noTextEditing = new Set(['head', 'style', 'title', 'template', 'noscript', 'textarea', 'select', 'option', 'xmp', 'noembed', 'noframes', 'plaintext'])
const controls = new Set(['input', 'textarea', 'select', 'button'])

// The preview is a disposable projection. Only source spans are edited; never
// serialize this tree back into the user's document.
export function artifactHtmlTextEditor(source: string): ArtifactHtmlEditor {
  const document = parse(source, { sourceCodeLocationInfo: true })
  const parts: ArtifactHtmlText[] = []
  const token = crypto.randomUUID()
  function visit(parent: Nodes.ParentNode, editable: boolean): void {
    for (const child of [...parent.childNodes]) {
      if (tree.isElementNode(child)) {
        if (removed.has(child.tagName)) { tree.detachNode(child); continue }
        child.attrs = child.attrs.filter(attr => !['nonce', marker, 'contenteditable', 'autofocus', 'href', 'action', 'formaction', 'target'].includes(attr.name))
        if (controls.has(child.tagName)) child.attrs.push({ name: 'disabled', value: '' })
        visit(child, editable && child.namespaceURI === html.NS.HTML && !noTextEditing.has(child.tagName))
        if (child.namespaceURI === html.NS.HTML && child.tagName === 'template') visit(tree.getTemplateContent(child as Nodes.Template), false)
      } else if (editable && tree.isTextNode(child) && child.value.trim() && child.sourceCodeLocation) {
        const { startOffset: start, endOffset: end } = child.sourceCodeLocation
        const raw = source.slice(start, end)
        // HTML tree repair can merge text across intervening tags (notably
        // around tables). Such a location is not a replaceable text-only span.
        if (decodeHTML(raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n')) !== child.value) continue
        const id = parts.length
        parts.push({ id, start, end, raw, text: child.value })
        const span = tree.createElement('span', html.NS.HTML, [{ name: marker, value: String(id) },
          { name: 'tabindex', value: '0' }, { name: 'role', value: 'button' }, { name: 'aria-label', value: `문장 편집: ${child.value}` }])
        tree.insertBefore(parent, span, child); tree.detachNode(child); tree.appendChild(span, child)
      }
    }
  }
  visit(document, true)
  const root = document.childNodes.find(tree.isElementNode)!
  const head = root.childNodes.find(node => tree.isElementNode(node) && node.tagName === 'head') as Nodes.Element
  let body = root.childNodes.find(node => tree.isElementNode(node) && node.tagName === 'body') as Nodes.Element | undefined
  if (!body) { body = tree.createElement('body', html.NS.HTML, []); tree.appendChild(root, body) }
  const policy = tree.createElement('meta', html.NS.HTML, [{ name: 'http-equiv', value: 'Content-Security-Policy' },
    { name: 'content', value: `default-src 'none'; script-src 'nonce-${token}'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'` }])
  const style = tree.createElement('style', html.NS.HTML, [])
  tree.insertText(style, `[${marker}]{cursor:text}[${marker}]:hover,[${marker}]:focus-visible{outline:2px solid #1684c9;outline-offset:2px}`)
  tree.appendChild(head, style)
  const script = tree.createElement('script', html.NS.HTML, [{ name: 'nonce', value: token }])
  tree.insertText(script, `(()=>{
    const nodes=new Map(Array.from(document.querySelectorAll('[${marker}]'),node=>[node,node.getAttribute('${marker}')]))
    const choose=event=>{
      event.preventDefault()
      const node=event.target instanceof Element?event.target.closest('[${marker}]'):null
      const id=node&&nodes.get(node)
      if(id!==undefined&&id!==null)window.parent.postMessage({type:'masc.artifact.text.selected.v1',token:${JSON.stringify(token)},id:Number(id)},'*')
    }
    document.addEventListener('click',choose,true)
    document.addEventListener('submit',event=>event.preventDefault(),true)
    document.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' ')choose(event)},true)
  })()`)
  tree.appendChild(body, script)
  // Apply CSP before even the original <html style=...> can start a request.
  return { document: '<!doctype html><meta charset="utf-8">' + serializeOuter(policy) + serialize(document), token, parts }
}

export function selectedArtifactHtmlText(editor: ArtifactHtmlEditor, message: unknown): ArtifactHtmlText | null {
  if (typeof message !== 'object' || message === null) return null
  const value = message as Record<string, unknown>
  if (value.type !== 'masc.artifact.text.selected.v1' || value.token !== editor.token
    || !Number.isSafeInteger(value.id) || typeof value.id !== 'number') return null
  return editor.parts[value.id] ?? null
}

export function escapeArtifactHtmlText(text: string): string {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
