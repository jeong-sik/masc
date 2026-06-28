export const STANDALONE_URL_RE = /^https?:\/\/\S+$/i
export const FENCE_OPEN_RE = /^ {0,3}(`{3,}|~{3,})/m

const STANDALONE_URL_LINE_RE = /^https?:\/\/\S+$/im
const HEADING_RE = /^ {0,3}#{1,6}\s+\S/m
const BLOCKQUOTE_RE = /^ {0,3}>/m
const LIST_RE = /^ {0,3}(?:[-*+]\s+|\d+[.)]\s+)/m
const HR_RE = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/m
const TABLE_ROW_RE = /^\s*\|.+\|\s*$/m
const TABLE_SEPARATOR_RE = /^\s*\|?\s*:?-{3,}:?\s*\|/m
const MARKDOWN_LINK_OR_IMAGE_RE = /!?\[[^\]]+]\([^)]+\)/
const INLINE_CODE_RE = /`[^`\n]+`/
const STRONG_RE = /(?:\*\*|__)\S[\s\S]*?\S(?:\*\*|__)/
const EMPHASIS_RE = /(^|[\s(])(?:\*|_)\S[^\n]*?\S(?:\*|_)(?=$|[\s).,!?;:])/

export function isSvgDocument(text: string): boolean {
  return /^<svg\b[\s\S]*<\/svg>$/i.test(text.trim())
}

export function hasMarkdownRenderCue(text: string): boolean {
  const trimmed = text.trim()
  if (!trimmed) return false
  return (
    FENCE_OPEN_RE.test(text)
    || HEADING_RE.test(text)
    || BLOCKQUOTE_RE.test(text)
    || LIST_RE.test(text)
    || HR_RE.test(text)
    || (TABLE_ROW_RE.test(text) && TABLE_SEPARATOR_RE.test(text))
    || MARKDOWN_LINK_OR_IMAGE_RE.test(text)
    || INLINE_CODE_RE.test(text)
    || STRONG_RE.test(text)
    || EMPHASIS_RE.test(text)
    || STANDALONE_URL_LINE_RE.test(text)
    || isSvgDocument(trimmed)
  )
}
