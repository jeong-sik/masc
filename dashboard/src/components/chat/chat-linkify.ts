import { escapeHtml } from '../../lib/html-escape'

const URL_RE = /(^|[\s(>])(https?:\/\/[^\s<)]+[^\s<).,!?:;])/g
const BOARD_POST_ID_RE = /(^|[\s([{"'`>])(p-[a-f0-9]{32})(?=$|[\s)\].,!?:;}"'`<])/gi
const ANCHOR_RE = /(<a\b[\s\S]*?<\/a>)/gi
const HTML_TAG_RE = /(<[^>]+>)/g

function boardPostHref(postId: string): string {
  return `#board?post=${encodeURIComponent(postId)}`
}

function boardPostLabel(postId: string): string {
  return postId.length <= 8 ? postId : postId.slice(0, 8)
}

function boardPostLink(postId: string): string {
  const label = boardPostLabel(postId)
  const escapedPostId = escapeHtml(postId)
  const escapedLabel = escapeHtml(label)
  const title = `보드 글 ${escapedPostId} 열기`
  return [
    `<a class="inline-link chat-board-post-link" href="${boardPostHref(postId)}"`,
    ` title="${title}" aria-label="${title}" data-board-post-id="${escapedPostId}">`,
    '<span class="chat-board-post-link-kind">보드 글</span>',
    `<span class="chat-board-post-link-id">${escapedLabel}</span>`,
    '</a>',
  ].join('')
}

function linkifyTextSegment(raw: string): string {
  return raw
    .replace(
      BOARD_POST_ID_RE,
      (_match, prefix: string, postId: string) =>
        `${prefix}${boardPostLink(postId)}`,
    )
    .replace(
      URL_RE,
      '$1<a class="inline-link" href="$2" target="_blank" rel="noopener noreferrer">$2</a>',
    )
}

/** Linkify plain URLs and MASC board post ids without touching existing tags. */
export function linkifyHtmlReferences(raw: string): string {
  if (!raw || (!raw.includes('http') && !/\bp-[a-f0-9]{32}\b/i.test(raw))) return raw
  return raw
    .split(ANCHOR_RE)
    .map((anchorPart) => {
      if (/^<a\b/i.test(anchorPart)) return anchorPart
      return anchorPart
        .split(HTML_TAG_RE)
        .map((part, i) => (i % 2 === 1 ? part : linkifyTextSegment(part)))
        .join('')
    })
    .join('')
}
