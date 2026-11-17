import { defaultTreeAdapter as tree, html, parse, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { decodeHTML } from 'entities'
import { addOfficeChartPreviews } from './artifact-office-chart-preview'
import { officeChartAttribute } from './artifact-office-chart'
import { artifactFrameRemovedTags, artifactTextFrame, type ArtifactTextEditor, type ArtifactTextPart } from './artifact-text-frame'

const noTextEditing = new Set(['head', 'style', 'title', 'template', 'noscript', 'textarea', 'select', 'option', 'xmp', 'noembed', 'noframes', 'plaintext'])

// Bind editable leaves to original source spans. The projection is never
// serialized back into the user's document.
export function artifactHtmlTextEditor(source: string): ArtifactTextEditor {
  const document = parse(source, { sourceCodeLocationInfo: true })
  addOfficeChartPreviews(document)
  const parts: ArtifactTextPart[] = []
  const token = crypto.randomUUID(), binding = `data-masc-binding-${token}`
  function visit(parent: Nodes.ParentNode, editable: boolean, inCell: boolean): void {
    for (const child of [...parent.childNodes]) {
      if (tree.isElementNode(child)) {
        if (artifactFrameRemovedTags.has(child.tagName)) continue
        const startTag = child.sourceCodeLocation?.startTag, endTag = child.sourceCodeLocation?.endTag
        const cell = ['td', 'th'].includes(child.tagName)
        const chartCaption = child.tagName === 'figcaption' && tree.isElementNode(parent) && parent.tagName === 'figure'
          && parent.attrs.some(attr => attr.name === officeChartAttribute)
        if (editable && child.namespaceURI === html.NS.HTML && (cell || chartCaption || (inCell && ['p', 'span', 'strong', 'em', 'u', 's', 'sub', 'sup'].includes(child.tagName)))
          && startTag && endTag && child.childNodes.every(node => tree.isTextNode(node) && !node.value.trim())) {
          const start = startTag.endOffset, end = endTag.startOffset, id = parts.length
          parts.push({ id, start, end, raw: source.slice(start, end), text: '' })
          tree.appendChild(child, tree.createElement('span', html.NS.HTML, [{ name: binding, value: String(id) }]))
        } else visit(child, editable && child.namespaceURI === html.NS.HTML && !noTextEditing.has(child.tagName), inCell || cell)
        if (child.namespaceURI === html.NS.HTML && child.tagName === 'template') visit(tree.getTemplateContent(child as Nodes.Template), false, false)
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
  visit(document, true, false)
  return artifactTextFrame(document, token, parts, binding)
}

export function escapeArtifactHtmlText(text: string): string {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
