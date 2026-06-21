const URL_RE = /(^|[\s(>])(https?:\/\/[^\s<)]+[^\s<).,!?:;])/g
const BOARD_POST_ID_RE = /(^|[\s([{"'`>])(p-[a-f0-9]{32})(?=$|[\s)\].,!?:;}"'`<])/gi
const ANCHOR_RE = /(<a\b[\s\S]*?<\/a>)/gi
const HTML_TAG_RE = /(<[^>]+>)/g

function boardPostHref(postId: string): string {
  return `#board?post=${encodeURIComponent(postId)}`
}

function linkifyTextSegment(raw: string): string {
  return raw
    .replace(
      BOARD_POST_ID_RE,
      (_match, prefix: string, postId: string) =>
        `${prefix}<a class="inline-link" href="${boardPostHref(postId)}" title="보드 게시글 열기">${postId}</a>`,
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
