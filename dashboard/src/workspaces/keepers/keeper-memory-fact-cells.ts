/**
 * Cells of the Keeper memory fact tables (`/keepers/:name/memory`).
 *
 * A fact table has one column of prose, the claim, beside short ones. A short
 * cell stays on one line and is cut with an ellipsis; a claim shows its first
 * lines until it is opened.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useId, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { formatDateTimeKo, formatTimeAgo } from '../../lib/format-time'
import type { OrdinaryMemoryFact, SourceBoundMemoryFact } from './types'

/** As many digits as #54930 gave the ID cell. */
const DIGEST_HEAD_LENGTH = 8

/** What tells one fact of a table from the others. */
export function ordinaryFactKey(fact: OrdinaryMemoryFact): string {
  return fact.memory_id || fact.claim
}

/** Paths are unique in a source-bound snapshot; pairing the path with its claim
 *  keeps a replaced claim for the same path from inheriting open state. */
export function sourceBoundFactKey(fact: SourceBoundMemoryFact): string {
  return `${fact.path}\n${fact.claim}`
}

/** The start of a digest's hex, without the `sha256:` scheme in front of it. */
export function digestHead(digest: string): string {
  return digest.slice(digest.indexOf(':') + 1).slice(0, DIGEST_HEAD_LENGTH)
}

/** A digest cut to its head. The whole value is the tooltip. */
export function FactDigest(props: { readonly digest: string }) {
  if (!props.digest) return html`<span class="dtable-absent">없음</span>`
  return html`<span class="kp-mem-clip kp-mem-id" title=${props.digest}>${digestHead(props.digest)}</span>`
}

/** How long ago a fact was seen. The decoder reports a time it did not get as 0. */
export function FactSeen(props: { readonly seenAt: number; readonly firstSeenAt?: number }) {
  if (props.seenAt <= 0) return html`<span class="dtable-absent">없음</span>`
  const seen = formatDateTimeKo(props.seenAt)
  const first = props.firstSeenAt
  const title = first !== undefined && first > 0 && first !== props.seenAt
    ? `마지막 ${seen} · 처음 ${formatDateTimeKo(first)}`
    : seen
  return html`<span class="kp-mem-clip" title=${title}>${formatTimeAgo(props.seenAt)}</span>`
}

/**
 * A claim, cut after its first lines. The button to open it is there only when
 * lines are cut, which is read from the drawn box: how many lines a claim
 * takes depends on the width of its column.
 */
export function FactClaim(props: {
  readonly open: boolean
  readonly onToggle: () => void
  readonly children: ComponentChildren
}) {
  const box = useRef<HTMLDivElement>(null)
  const boxId = useId()
  const [cut, setCut] = useState(false)

  useLayoutEffect(() => {
    const element = box.current
    if (!element) return undefined
    const read = () => setCut(element.scrollHeight > element.clientHeight + 1)
    read()
    if (typeof ResizeObserver === 'undefined') return undefined
    const observer = new ResizeObserver(read)
    observer.observe(element)
    return () => observer.disconnect()
  }, [props.open])

  return html`
    <div class="kp-mem-claim" data-open=${props.open ? 'true' : undefined}>
      <div ref=${box} id=${boxId} class="kp-mem-claim-text">${props.children}</div>
      ${(cut || props.open) && html`
        <button
          type="button"
          class="kp-mem-claim-toggle"
          aria-expanded=${props.open}
          aria-controls=${boxId}
          onClick=${props.onToggle}
        >
          ${props.open ? '접기' : '더 보기'}
        </button>
      `}
    </div>
  `
}

/** `set` with `key` added, or removed when it was there. */
export function withToggled(set: ReadonlySet<string>, key: string): ReadonlySet<string> {
  const next = new Set(set)
  if (!next.delete(key)) next.add(key)
  return next
}
