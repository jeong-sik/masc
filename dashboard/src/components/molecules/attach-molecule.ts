// keeper-v2 design attachment molecule — Attach from
// prototypes/keeper-v2/molecules.jsx, fed by the live ChatAttachBlock
// (src/types/core.ts). Media safety rules mirror chat/primitives.ts: only
// http(s)/blob URLs and data:image/ payloads render.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { ChatAttachBlock } from '../../types'
import { sanitizeHtml } from '../../lib/dompurify'

function isSafeAttachSrc(url: string): boolean {
  try {
    const u = new URL(url, typeof window !== 'undefined' ? window.location.href : 'http://localhost')
    if (u.protocol === 'http:' || u.protocol === 'https:' || u.protocol === 'blob:') return true
  } catch {
    // fall through to the data: check
  }
  return url.slice(0, 64).toLowerCase().startsWith('data:image/')
}

export function MoleculeAttach({
  name,
  dims,
  src,
  svg,
  ph,
  via,
  size,
  tag,
  clip = '◫',
}: ChatAttachBlock & { tag?: string; clip?: string }): VNode {
  const safeSrc = src && isSafeAttachSrc(src) ? src : null
  const capText = [via, size].filter(Boolean).join(' · ')
  return html`
    <div class="attach">
      <div class="attach-hd">
        <span class="attach-clip">${clip}</span>
        <span class="attach-name mono">${name}</span>
        ${dims ? html`<span class="attach-dims mono">${dims}</span>` : null}
      </div>
      <div class="attach-frame">
        ${safeSrc
          ? html`<img src=${safeSrc} alt=${name} />`
          : svg
            ? html`<span dangerouslySetInnerHTML=${{ __html: sanitizeHtml(svg) }} />`
            : html`<div class="img-ph">${ph || '첨부 이미지'}${src ? ' (unsafe URL)' : ''}</div>`}
      </div>
      ${capText || tag
        ? html`<div class="attach-cap">${tag ? html`<span class="attach-tag">${tag}</span>` : null}${capText}</div>`
        : null}
    </div>
  `
}
