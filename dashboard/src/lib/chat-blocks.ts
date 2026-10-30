import type { ChatBlock, ChatImageBlock, ChatLinkBlock } from '../types'
import { escapeHtml } from './html-escape'

const IMAGE_EXTENSIONS = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'])

function isImageUrl(url: string): boolean {
  try {
    const pathname = new URL(url).pathname.toLowerCase()
    const ext = pathname.split('.').pop() ?? ''
    return IMAGE_EXTENSIONS.has(ext)
  } catch {
    return false
  }
}

function hostnameTitle(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, '')
  } catch {
    return url
  }
}

/** Detect a single URL that occupies the whole trimmed line. */
const STANDALONE_URL_RE = /^https?:\/\/\S+$/i

function lineToBlock(line: string): ChatBlock | null {
  const trimmed = line.trim()
  if (!trimmed) return null
  if (STANDALONE_URL_RE.test(trimmed)) {
    if (isImageUrl(trimmed)) {
      const block: ChatImageBlock = { t: 'image', src: trimmed }
      return block
    }
    const block: ChatLinkBlock = {
      t: 'link',
      url: trimmed,
      title: hostnameTitle(trimmed),
      meta: hostnameTitle(trimmed),
    }
    return block
  }
  return { t: 'p', html: escapeHtml(line) }
}

/**
 * Parse assistant markdown/plain text into rich chat blocks.
 *
 * - Markdown images `![alt](url)` become image blocks.
 * - Bare image URLs (png/jpg/gif/webp/svg) on their own line become image blocks.
 * - Other standalone URLs become link cards with a hostname-derived title.
 * - Remaining text becomes escaped HTML text blocks.
 */
export function parseTextToChatBlocks(text: string): ChatBlock[] {
  const blocks: ChatBlock[] = []
  const imageRe = /!\[([^\]]*)\]\(([^)]+)\)/g
  let lastIndex = 0
  let match: RegExpExecArray | null

  while ((match = imageRe.exec(text)) !== null) {
    const before = text.slice(lastIndex, match.index)
    pushTextFragment(blocks, before)
    const [, alt, url] = match
    blocks.push({ t: 'image', src: url, cap: alt || undefined })
    lastIndex = imageRe.lastIndex
  }

  pushTextFragment(blocks, text.slice(lastIndex))
  return blocks
}

function pushTextFragment(blocks: ChatBlock[], fragment: string): void {
  const lines = fragment.split('\n')
  lines.forEach((line) => {
    const block = lineToBlock(line)
    if (block) blocks.push(block)
  })
}
