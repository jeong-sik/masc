import { marked, type Token, type Tokens } from 'marked'
import DOMPurify from 'dompurify'
import type { ChatBlock, ChatCalloutSeverity, ChatTableCellValue } from '../../types'

function escapeHtml(raw: string): string {
  return raw.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** Linkify plain URLs without touching existing HTML tags. */
function linkifyHtml(raw: string): string {
  if (!raw || raw.indexOf('http') === -1) return raw
  const linkRe = /(^|[\s(>])(https?:\/\/[^\s<)]+[^\s<).,!?:;])/g
  return raw
    .split(/(<[^>]+>)/g)
    .map((part, i) =>
      i % 2 === 1
        ? part
        : part.replace(linkRe, '$1<a class="inline-link" href="$2" target="_blank" rel="noopener noreferrer">$2</a>'),
    )
    .join('')
}

function sanitizeHtml(raw: string): string {
  return DOMPurify.sanitize(raw)
}

function inlineHtml(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ''
  const parsed = marked.parseInline(trimmed) as string
  return sanitizeHtml(linkifyHtml(parsed))
}

function cellValue(raw: string): ChatTableCellValue {
  const text = inlineHtml(raw)
  const plain = text.replace(/<[^>]+>/g, '').trim()
  const num = /^-?\d+(\.\d+)?%?$/.test(plain)
  const muted = plain === '' || /^(n\/a|n\.a\.|—|-)$/i.test(plain)
  return num || muted ? { v: text, num, muted } : text
}

const CALLOUT_TAG_RE = /\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION|DANGER|WARN|ERROR)\]\s*/i

function detectCalloutSeverity(html: string): ChatCalloutSeverity {
  const match = html.match(CALLOUT_TAG_RE)
  if (!match) return 'info'
  const kind = (match[1] ?? '').toUpperCase()
  if (['NOTE', 'TIP', 'IMPORTANT'].includes(kind)) return 'info'
  if (['WARNING', 'WARN'].includes(kind)) return 'warn'
  return 'bad'
}

function parseBlockquote(token: Tokens.Blockquote): ChatBlock {
  const inner = marked.parser(token.tokens).trim()
  const severity = detectCalloutSeverity(inner)
  const body = inner
    .replace(CALLOUT_TAG_RE, '')
    .replace(/^<blockquote>\s*/i, '')
    .replace(/<\/blockquote>\s*$/i, '')
    .trim()
  return { t: 'callout', severity, html: sanitizeHtml(linkifyHtml(body)) }
}

function parseList(token: Tokens.List): ChatBlock {
  const items = token.items.map((item) => sanitizeHtml(linkifyHtml(marked.parseInline(item.text) as string)))
  return { t: 'ul', items }
}

function parseParagraph(token: Tokens.Paragraph): ChatBlock | null {
  if (token.tokens.length === 1 && token.tokens[0]?.type === 'image') {
    const img = token.tokens[0] as Tokens.Image
    return { t: 'image', src: img.href, cap: img.text || img.title || undefined }
  }
  const trimmed = token.text.trim()
  if (/^<svg\b[\s\S]*<\/svg>$/i.test(trimmed)) {
    return { t: 'svg', svg: trimmed, cap: undefined }
  }
  const html = inlineHtml(token.text).trim()
  return html ? { t: 'p', html } : null
}

function parseCode(token: Tokens.Code): ChatBlock {
  const lang = token.lang?.trim().toLowerCase() || undefined
  if (lang?.startsWith('mermaid')) {
    return { t: 'mermaid', source: token.text }
  }
  return { t: 'code', cap: lang, html: escapeHtml(token.text) }
}

function parseHeading(token: Tokens.Heading): ChatBlock {
  return { t: 'h4', html: inlineHtml(token.text) }
}

function parseTable(token: Tokens.Table): ChatBlock {
  return {
    t: 'table',
    head: token.header.map((cell) => cellValue(cell.text)),
    rows: token.rows.map((row) => row.map((cell) => cellValue(cell.text))),
  }
}

function parseHtml(token: Tokens.HTML): ChatBlock | null {
  const trimmed = token.text.trim()
  if (/^<svg\b[\s\S]*<\/svg>$/i.test(trimmed)) {
    return { t: 'svg', svg: trimmed, cap: undefined }
  }
  // Treat other top-level HTML as a paragraph after sanitization.
  const html = sanitizeHtml(linkifyHtml(trimmed)).trim()
  return html ? { t: 'p', html } : null
}

function tokenToBlock(token: Token): ChatBlock | ChatBlock[] | null {
  switch (token.type) {
    case 'paragraph':
      return parseParagraph(token as Tokens.Paragraph)
    case 'code':
      return parseCode(token as Tokens.Code)
    case 'heading':
      return parseHeading(token as Tokens.Heading)
    case 'list':
      return parseList(token as Tokens.List)
    case 'blockquote':
      return parseBlockquote(token as Tokens.Blockquote)
    case 'table':
      return parseTable(token as Tokens.Table)
    case 'html':
      return parseHtml(token as Tokens.HTML)
    case 'hr':
    case 'space':
      return null
    default:
      return null
  }
}

/** Convert assistant/system markdown text into the dashboard's ChatBlock[] format. */
export function parseMarkdownToBlocks(markdown: string): ChatBlock[] {
  if (!markdown || !markdown.trim()) return []
  try {
    const tokens = marked.lexer(markdown)
    const blocks: ChatBlock[] = []
    for (const token of tokens) {
      const block = tokenToBlock(token)
      if (!block) continue
      if (Array.isArray(block)) blocks.push(...block)
      else blocks.push(block)
    }
    return blocks
  } catch {
    return []
  }
}
