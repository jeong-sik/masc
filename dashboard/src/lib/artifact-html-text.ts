import { defaultTreeAdapter as tree, html, parse, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { decodeHTML } from 'entities'
import { artifactFrameRemovedTags, artifactTextFrame, type ArtifactTextEditor, type ArtifactTextPart } from './artifact-text-frame'

const noTextEditing = new Set(['head', 'style', 'title', 'template', 'noscript', 'textarea', 'select', 'option', 'xmp', 'noembed', 'noframes', 'plaintext'])

// Bind editable leaves to original source spans. The projection is never
// serialized back into the user's document.
export function artifactHtmlTextEditor(source: string): ArtifactTextEditor {
  const document = parse(source, { sourceCodeLocationInfo: true })
  const parts: ArtifactTextPart[] = []
  const token = crypto.randomUUID(), binding = `data-masc-binding-${token}`
  function visit(parent: Nodes.ParentNode, editable: boolean): void {
    for (const child of [...parent.childNodes]) {
      if (tree.isElementNode(child)) {
        if (artifactFrameRemovedTags.has(child.tagName)) continue
        visit(child, editable && child.namespaceURI === html.NS.HTML && !noTextEditing.has(child.tagName))
        if (child.namespaceURI === html.NS.HTML && child.tagName === 'template') visit(tree.getTemplateContent(child as Nodes.Template), false)
      } else if (editable && tree.isTextNode(child) && child.value.trim() && child.sourceCodeLocation) {
        const { startOffset: start, endOffset: end } = child.sourceCodeLocation
        const raw = source.slice(start, end)
        // Parser tree repair can merge text across intervening tags. Such a
        // range must never become a text-only source replacement.
        if (decodeHTML(raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n')) !== child.value) continue
        const id = parts.length
        parts.push({ id, start, end, raw, text: child.value })
        const span = tree.createElement('span', html.NS.HTML, [{ name: binding, value: String(id) }])
        tree.insertBefore(parent, span, child); tree.detachNode(child); tree.appendChild(span, child)
      }
    }
  }
  visit(document, true)
  return artifactTextFrame(document, token, parts, binding)
}

export function escapeArtifactHtmlText(text: string): string {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
