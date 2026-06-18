import createDOMPurify, { type Config, type DOMPurify } from 'dompurify'

let purifier: DOMPurify | null = null
let purifierDocument: Document | null = null
let purifierPassedSmokeTest = false

const DEFAULT_ALLOWED_TAGS = [
  'a', 'blockquote', 'br', 'code', 'del', 'details', 'div', 'em', 'h1', 'h2', 'h3',
  'h4', 'h5', 'h6', 'hr', 'img', 'li', 'ol', 'p', 'pre', 'span', 'strong',
  'summary', 'table', 'tbody', 'td', 'th', 'thead', 'tr', 'ul',
]

const DEFAULT_ALLOWED_ATTR = [
  'align', 'alt', 'class', 'href', 'rel', 'src', 'target', 'title',
]

const SVG_ALLOWED_TAGS = [
  'circle', 'clipPath', 'defs', 'desc', 'ellipse', 'g', 'line', 'linearGradient',
  'marker', 'path', 'polygon', 'polyline', 'radialGradient', 'rect', 'stop',
  'svg', 'text', 'title', 'tspan',
]

const SVG_ALLOWED_ATTR = [
  'alignment-baseline', 'aria-label', 'class', 'clip-path', 'cx', 'cy', 'd', 'dx',
  'dy', 'fill', 'fill-opacity', 'font-family', 'font-size', 'height', 'id',
  'marker-end', 'marker-mid', 'marker-start', 'offset', 'opacity', 'points', 'r',
  'rx', 'ry', 'stroke', 'stroke-dasharray', 'stroke-linecap', 'stroke-linejoin',
  'stroke-opacity', 'stroke-width', 'style', 'text-anchor', 'transform', 'viewBox',
  'width', 'x', 'x1', 'x2', 'xlink:href', 'xmlns', 'y', 'y1', 'y2',
]

const DROP_WITH_CONTENT_TAGS = new Set([
  'base', 'embed', 'iframe', 'link', 'meta', 'noscript', 'object', 'script',
  'style', 'template',
])

const URI_ATTRS = new Set([
  'action', 'formaction', 'href', 'src', 'xlink:href',
])

interface ResolvedFallbackConfig {
  allowedTags: Set<string>
  allowedAttrs: Set<string>
  forbiddenTags: Set<string>
  forbiddenAttrs: Set<string>
  allowAriaAttr: boolean
  allowDataAttr: boolean
}

function currentWindow(): Window & typeof globalThis {
  if (typeof window === 'undefined' || !window.document) {
    throw new Error('DOMPurify requires an active window.document')
  }
  return window as Window & typeof globalThis
}

function getPurifier(): DOMPurify {
  const activeWindow = currentWindow()
  if (!purifier || purifierDocument !== activeWindow.document) {
    purifier = createDOMPurify(activeWindow)
    purifierDocument = activeWindow.document
    purifierPassedSmokeTest = purifierPassesSmokeTest(purifier)
  }
  return purifier
}

export type SanitizeConfig = Config

export function sanitizeHtml(raw: string, config?: Config): string {
  const activePurifier = getPurifier()
  if (!purifierPassedSmokeTest) return fallbackSanitizeHtml(raw, config)
  return activePurifier.sanitize(raw, config)
}

function purifierPassesSmokeTest(activePurifier: DOMPurify): boolean {
  if (!activePurifier.isSupported) return false
  const scriptOutput = activePurifier.sanitize('<p>ok<script>alert(1)</script></p>')
  const linkOutput = activePurifier.sanitize('<a href="javascript:alert(1)">x</a>', {
    ALLOWED_TAGS: ['a'],
    ALLOWED_ATTR: ['href'],
  })
  const preOutput = activePurifier.sanitize('<pre><code>x</code></pre>', {
    ALLOWED_TAGS: ['pre', 'code'],
    ALLOWED_ATTR: [],
  })
  return !containsUnsafeMarkup(scriptOutput)
    && !containsUnsafeMarkup(linkOutput)
    && preOutput.includes('<pre')
}

function containsUnsafeMarkup(value: string): boolean {
  const normalized = value.toLowerCase()
  return normalized.includes('<script')
    || normalized.includes('javascript:')
    || normalized.includes('vbscript:')
}

function fallbackSanitizeHtml(raw: string, config?: Config): string {
  const template = currentWindow().document.createElement('template')
  template.innerHTML = raw
  sanitizeChildren(template.content, resolveFallbackConfig(config))
  return template.innerHTML
}

function resolveFallbackConfig(config?: Config): ResolvedFallbackConfig {
  const svgProfile = usesSvgProfile(config)
  const tags = normalizeSet(config?.ALLOWED_TAGS ?? (svgProfile ? SVG_ALLOWED_TAGS : DEFAULT_ALLOWED_TAGS))
  const attrs = normalizeSet(config?.ALLOWED_ATTR ?? (svgProfile ? SVG_ALLOWED_ATTR : DEFAULT_ALLOWED_ATTR))
  addArrayConfigValues(tags, config?.ADD_TAGS)
  addArrayConfigValues(attrs, config?.ADD_ATTR)
  return {
    allowedTags: tags,
    allowedAttrs: attrs,
    forbiddenTags: normalizeSet(config?.FORBID_TAGS ?? []),
    forbiddenAttrs: normalizeSet(config?.FORBID_ATTR ?? []),
    allowAriaAttr: config?.ALLOW_ARIA_ATTR !== false,
    allowDataAttr: config?.ALLOW_DATA_ATTR !== false,
  }
}

function usesSvgProfile(config?: Config): boolean {
  const profiles = config?.USE_PROFILES
  return !!profiles && typeof profiles === 'object' && profiles.svg === true
}

function normalizeSet(values: ReadonlyArray<string>): Set<string> {
  return new Set(values.map(value => value.toLowerCase()))
}

function addArrayConfigValues(target: Set<string>, values: Config['ADD_TAGS'] | Config['ADD_ATTR']): void {
  if (!Array.isArray(values)) return
  for (const value of values) target.add(value.toLowerCase())
}

function sanitizeChildren(parent: ParentNode, config: ResolvedFallbackConfig): void {
  let node = parent.firstChild
  while (node) {
    const next = node.nextSibling
    if (node.nodeType === Node.ELEMENT_NODE) {
      sanitizeElement(node as Element, config)
    } else if (node.nodeType !== Node.TEXT_NODE) {
      node.parentNode?.removeChild(node)
    }
    node = next
  }
}

function sanitizeElement(element: Element, config: ResolvedFallbackConfig): void {
  const tag = element.tagName.toLowerCase()
  if (DROP_WITH_CONTENT_TAGS.has(tag) || config.forbiddenTags.has(tag)) {
    element.remove()
    return
  }
  if (!config.allowedTags.has(tag)) {
    sanitizeChildren(element, config)
    unwrapElement(element)
    return
  }
  sanitizeAttributes(element, tag, config)
  sanitizeChildren(element, config)
}

function sanitizeAttributes(element: Element, tag: string, config: ResolvedFallbackConfig): void {
  for (const attr of Array.from(element.attributes)) {
    const attrName = attr.name.toLowerCase()
    if (!isAllowedAttr(attrName, config) || !isSafeAttrValue(tag, attrName, attr.value)) {
      element.removeAttribute(attr.name)
    }
  }
}

function isAllowedAttr(attrName: string, config: ResolvedFallbackConfig): boolean {
  if (config.forbiddenAttrs.has(attrName)) return false
  if (config.allowedAttrs.has(attrName)) return true
  if (config.allowAriaAttr && attrName.startsWith('aria-')) return true
  if (config.allowDataAttr && attrName.startsWith('data-')) return true
  return false
}

function isSafeAttrValue(tag: string, attrName: string, value: string): boolean {
  if (attrName.startsWith('on')) return false
  if (attrName === 'style') return isSafeStyle(value)
  if (!URI_ATTRS.has(attrName)) return true
  return isSafeUri(tag, attrName, value)
}

function isSafeUri(tag: string, attrName: string, value: string): boolean {
  const compact = value.replace(/[\u0000-\u001F\u007F\s]+/g, '').toLowerCase()
  if (compact === '' || compact.startsWith('#')) return true
  if (compact.startsWith('javascript:') || compact.startsWith('vbscript:')) return false
  if (compact.startsWith('data:')) {
    return tag === 'img' && attrName === 'src' && compact.startsWith('data:image/')
  }
  try {
    const parsed = new URL(value, currentWindow().location.href)
    return ['http:', 'https:', 'mailto:', 'tel:'].includes(parsed.protocol)
  } catch {
    return value.startsWith('/') || value.startsWith('./') || value.startsWith('../')
  }
}

function isSafeStyle(value: string): boolean {
  const normalized = value.replace(/\\[\da-f]{1,6}\s?/gi, '').toLowerCase()
  return !/(?:url\s*\(|expression\s*\(|javascript:|vbscript:|behavior\s*:)/.test(normalized)
}

function unwrapElement(element: Element): void {
  const parent = element.parentNode
  if (!parent) return
  while (element.firstChild) parent.insertBefore(element.firstChild, element)
  parent.removeChild(element)
}
