import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  KeeperTraceEvent,
  KeeperTraceSource,
  keeperTraceState,
} from './keeper-trace-store'

/**
 * RFC-0028 PR-β: keeper-trace gutter chip overlay.
 *
 * Reads `keeperTraceState` (the 4-source stitched store from PR-α) and
 * renders a stacked gutter chip per RFC §5: cap=3 visible chips per
 * (keeperName, line) bucket plus a `+N` overflow indicator. Each chip is
 * colored by source (anchored-thread / cascade-hop / bdi-snapshot /
 * decision-log) and exposes a hover tooltip with the underlying event
 * details.
 *
 * Bucket key (RFC §5 + §11 #3):
 *   `${keeperName}@${line ?? 'no-line'}`
 *
 * Events without a line (bdi-snapshot, decision-log without anchor) are
 * grouped under the keeper-level bucket, so a sidebar overlay can render
 * them next to the keeper avatar rather than at a specific line. PR-β
 * keeps the bucket-by-line shape; consumers (editor gutter, sidebar
 * keeper rail) decide where to mount the chips.
 *
 * Conflict avoidance (RFC §10): the `keeper-trace` IDE_LAYERS entry
 * declares `conflictsWith: ['cascade']` so activating either layer drops
 * the other automatically — see `layered-overlay.ts`. PR-β does not
 * coordinate with cascade-overlay directly; the layer registry handles it.
 */

export const TRACE_CHIP_CAP = 3

/** Source → chip background color (semantic, not literal). */
const SOURCE_COLORS: Record<KeeperTraceSource, string> = {
  'anchored-thread': 'var(--color-status-info, #4a90e2)',
  'cascade-hop': 'var(--color-accent-fg, #8b5cf6)',
  'bdi-snapshot': 'var(--color-status-ok, #2dba4e)',
  'decision-log': 'var(--color-status-warn, #d97706)',
}

/** Source → label glyph for tooltip + ARIA. */
const SOURCE_LABELS: Record<KeeperTraceSource, string> = {
  'anchored-thread': 'thread',
  'cascade-hop': 'cascade',
  'bdi-snapshot': 'BDI',
  'decision-log': 'decision',
}

interface TraceBucket {
  readonly keeperName: string
  readonly line: number | null
  readonly events: ReadonlyArray<KeeperTraceEvent>
}

/**
 * Group events by (keeperName, line). Each bucket sorts events newest-first
 * (descending tsMs) so the head chip surfaces the most recent burst.
 */
export function bucketTraceEvents(
  events: ReadonlyArray<KeeperTraceEvent>,
): ReadonlyArray<TraceBucket> {
  const map = new Map<string, KeeperTraceEvent[]>()
  for (const event of events) {
    const lineKey = lineOf(event) ?? 'no-line'
    const key = `${event.keeperName}@${lineKey}`
    let group = map.get(key)
    if (!group) {
      group = []
      map.set(key, group)
    }
    group.push(event)
  }
  const buckets: TraceBucket[] = []
  for (const [, group] of map) {
    group.sort((a, b) => b.tsMs - a.tsMs)
    const head = group[0]!
    buckets.push({
      keeperName: head.keeperName,
      line: lineOf(head),
      events: group,
    })
  }
  // Stable bucket order: most recent head event first.
  buckets.sort((a, b) => (b.events[0]?.tsMs ?? 0) - (a.events[0]?.tsMs ?? 0))
  return buckets
}

function lineOf(event: KeeperTraceEvent): number | null {
  return event.source === 'anchored-thread' ? event.line : null
}

interface OverlayKeeperTraceProps {
  /**
   * When `false`, the overlay renders nothing (the IDE_LAYERS toggle is
   * off). The component still subscribes to the store so toggling on is
   * cheap, but the active=false path short-circuits before any DOM work.
   */
  readonly active: boolean
  /**
   * Optional filter. When provided, only the named keeper's buckets render.
   * Used by inspector-side mounts (a single-keeper rail) to scope the
   * overlay; editor-side mounts pass `undefined`.
   */
  readonly keeperFilter?: string
}

function useTraceEvents(): ReadonlyArray<KeeperTraceEvent> {
  const [snapshot, setSnapshot] = useState(keeperTraceState.value)
  useEffect(() => keeperTraceState.subscribe(value => setSnapshot(value)), [])
  return snapshot.events
}

const OVERLAY_CONTAINER_STYLE = {
  display: 'grid',
  gap: 'var(--sp-1)',
  fontSize: 'var(--fs-11)',
} as const

const STACK_STYLE = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: '2px',
} as const

const CHIP_STYLE = {
  display: 'inline-block',
  width: '8px',
  height: '8px',
  borderRadius: '50%',
  border: '1px solid var(--color-bg-surface)',
} as const

const OVERFLOW_STYLE = {
  marginLeft: '4px',
  color: 'var(--color-fg-muted)',
  fontSize: 'var(--fs-11)',
} as const

function formatTooltip(event: KeeperTraceEvent): string {
  const sourceLabel = SOURCE_LABELS[event.source]
  const lineSuffix = event.source === 'anchored-thread' && event.line !== null
    ? ` L${event.line}`
    : ''
  const countSuffix = event.count > 1 ? ` ×${event.count}` : ''
  return `${sourceLabel}${lineSuffix}${countSuffix}`
}

export function OverlayKeeperTrace({ active, keeperFilter }: OverlayKeeperTraceProps) {
  const events = useTraceEvents()
  if (!active) return null

  const filtered = keeperFilter
    ? events.filter(e => e.keeperName === keeperFilter)
    : events
  if (filtered.length === 0) return null

  const buckets = bucketTraceEvents(filtered)
  if (buckets.length === 0) return null

  return html`
    <div
      role="region"
      aria-label="Keeper trace overlay"
      data-overlay="keeper-trace"
      style=${OVERLAY_CONTAINER_STYLE}
    >
      ${buckets.map(bucket => html`
        <${BucketRow} key=${`${bucket.keeperName}@${bucket.line ?? 'no-line'}`} bucket=${bucket} />
      `)}
    </div>
  `
}

function BucketRow({ bucket }: { readonly bucket: TraceBucket }) {
  const visible = bucket.events.slice(0, TRACE_CHIP_CAP)
  const overflow = bucket.events.length - visible.length
  const lineLabel = bucket.line !== null ? `L${bucket.line}` : '—'

  return html`
    <div
      role="group"
      data-keeper=${bucket.keeperName}
      data-line=${bucket.line ?? 'no-line'}
      style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)' }}
    >
      <span style=${{ color: 'var(--color-accent-fg)', font: 'var(--type-eyebrow)' }}>
        ${bucket.keeperName}
      </span>
      <span style=${{ color: 'var(--color-fg-muted)' }}>${lineLabel}</span>
      <ul role="list" aria-label=${`${bucket.keeperName} trace events`} style=${STACK_STYLE}>
        ${visible.map(event => html`
          <li
            role="img"
            data-source=${event.source}
            data-count=${event.count}
            aria-label=${formatTooltip(event)}
            title=${formatTooltip(event)}
            style=${{ ...CHIP_STYLE, background: SOURCE_COLORS[event.source] }}
          />
        `)}
      </ul>
      ${overflow > 0
        ? html`<span aria-label=${`${overflow} more`} data-overflow=${overflow} style=${OVERFLOW_STYLE}>+${overflow}</span>`
        : null}
    </div>
  `
}
