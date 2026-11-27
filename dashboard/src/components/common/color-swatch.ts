// Color swatches for CSS hex literals in rendered Markdown.
//
// The grammar matches the TUI's Css lexer (lib/masc_tui/ui/code_lexer.ml):
// '#' and exactly six hex digits with a name character on neither side.
// Comments and strings are skipped; #RGB and #RRGGBBAA stay text. Inline code
// shows a swatch only when its whole text is one literal, the rule GitHub
// uses for colors in backticks.

import './color-swatch.css'

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/
const HEX_COLOR_LENGTH = '#RRGGBB'.length
const NAME_CHAR = /[-\w]/
const CSS_FENCE_CLASS = 'language-css'

export type ColorLiteral = { start: number; color: string }

export function isCssColorLiteral(text: string): boolean {
  return HEX_COLOR.test(text)
}

function quotedEnd(text: string, open: number): number {
  const quote = text[open]
  let index = open + 1
  while (index < text.length) {
    const ch = text[index]
    if (ch === '\\') index += 2
    else if (ch === quote) return index + 1
    else index += 1
  }
  return text.length
}

function colorAt(text: string, index: number): string | undefined {
  const end = index + HEX_COLOR_LENGTH
  if (end > text.length) return undefined
  const literal = text.slice(index, end)
  if (!isCssColorLiteral(literal)) return undefined
  if (index > 0 && NAME_CHAR.test(text[index - 1] ?? '')) return undefined
  if (end < text.length && NAME_CHAR.test(text[end] ?? '')) return undefined
  return literal
}

export function cssColorLiterals(text: string): ColorLiteral[] {
  const found: ColorLiteral[] = []
  let index = 0
  while (index < text.length) {
    if (text.startsWith('/*', index)) {
      const close = text.indexOf('*/', index + 2)
      index = close < 0 ? text.length : close + 2
      continue
    }
    const ch = text[index]
    if (ch === '"' || ch === "'") {
      index = quotedEnd(text, index)
      continue
    }
    const color = colorAt(text, index)
    if (color) {
      found.push({ start: index, color })
      index += HEX_COLOR_LENGTH
      continue
    }
    index += 1
  }
  return found
}

function swatchBeforeFenceLiterals(code: HTMLElement, makeSwatch: (color: string) => HTMLElement) {
  const literals = cssColorLiterals(code.textContent ?? '')
  if (literals.length === 0) return
  const texts: Array<{ node: Text; start: number }> = []
  const walker = code.ownerDocument.createTreeWalker(code, NodeFilter.SHOW_TEXT)
  let offset = 0
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!(node instanceof Text)) continue
    texts.push({ node, start: offset })
    offset += node.data.length
  }
  // Insert from the last literal: splitting a text node keeps its head, so
  // the offsets of the literals before it stay valid.
  for (const literal of literals.reverse()) {
    let host = texts[0]
    for (const text of texts) {
      if (text.start <= literal.start) host = text
    }
    if (!host) return
    host.node.splitText(literal.start - host.start).before(makeSwatch(literal.color))
  }
}

/** Put a swatch before every CSS color literal under root. Returns a function
 * that removes them and joins the split text nodes again. */
export function decorateColorLiterals(root: HTMLElement): () => void {
  const swatches: HTMLElement[] = []
  const fences: HTMLElement[] = []
  const makeSwatch = (color: string) => {
    const swatch = root.ownerDocument.createElement('span')
    swatch.className = 'md-color-swatch'
    swatch.setAttribute('aria-hidden', 'true')
    swatch.style.backgroundColor = color
    swatches.push(swatch)
    return swatch
  }
  for (const code of root.querySelectorAll<HTMLElement>('code')) {
    if (code.parentElement?.localName !== 'pre') {
      const text = code.textContent ?? ''
      if (isCssColorLiteral(text)) code.prepend(makeSwatch(text))
    } else if ([...code.classList].some(name => name.toLowerCase() === CSS_FENCE_CLASS)) {
      swatchBeforeFenceLiterals(code, makeSwatch)
      fences.push(code)
    }
  }
  return () => {
    for (const swatch of swatches) swatch.remove()
    for (const fence of fences) fence.normalize()
  }
}
