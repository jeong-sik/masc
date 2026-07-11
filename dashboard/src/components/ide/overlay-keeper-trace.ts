import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  filterTraceEventsByReplay,
  KeeperTraceEvent,
  KeeperTraceSource,
  keeperTraceState,
} from './keeper-trace-store'
import { ideReplayUntilMs, setIdeReplayUntilMs } from './ide-replay-state'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import { focusIdeContextAnchor } from './ide-state'
import { routeLinkLabels } from './ide-context-route-helpers'

/**
 * RFC-0028 PR-β: keeper-trace gutter chip overlay.
 *
 * Reads `keeperTraceState` (the stitched trace store) and
 * renders a stacked gutter chip per RFC §5: cap=3 visible chips per
 * (keeperName, line) bucket plus a `+N` overflow indicator. Each chip is
 * colored by source (anchored-thread / runtime-hop / decision-log /
 * activity-event) and exposes a hover tooltip with the
 * underlying event details.
 *
 * Bucket key (RFC §5 + §11 #3):
 *   `${keeperName}@${line ?? 'no-line'}`
 *
 * Events without a line (decision-log without anchor) are
 * grouped under the keeper-level bucket, so a sidebar overlay can render
 * them next to the keeper avatar rather than at a specific line. PR-β
 * keeps the bucket-by-line shape; consumers (editor gutter, sidebar
 * keeper rail) decide where to mount the chips.
 *
 * Conflict avoidance (RFC §10): the `keeper-trace` IDE_LAYERS entry used to
 * declare `conflictsWith: ['runtime']` so activating either layer dropped
 * the other automatically (see `layered-overlay.ts`). The 'runtime' layer
 * was removed (masc#24069 #49 — decorative chip, no backing overlay), so
 * this entry no longer needs a conflict declaration.
 */

export const TRACE_CHIP_CAP = 3
const TRACE_ROUTE_LINK_CAP = 10

/** Source → chip background color (semantic, not literal). */
const SOURCE_COLORS: Record<KeeperTraceSource, string> = {
  'anchored-thread': 'var(--color-status-info)',
  'runtime-hop': 'var(--color-accent-fg)',
  'decision-log': 'var(--color-status-warn)',
  'activity-event': 'var(--color-status-info)',
}

/** Source → label glyph for tooltip + ARIA. */
const SOURCE_LABELS: Record<KeeperTraceSource, string> = {
  'anchored-thread': 'thread',
  'runtime-hop': 'runtime',
  'decision-log': 'decision',
  'activity-event': 'activity',
}

interface TraceBucket {
  readonly keeperName: string
  readonly filePath: string | null
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
    const fileKey = filePathOf(event) ?? 'no-file'
    const key = `${event.keeperName}@${fileKey}@${lineKey}`
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
      filePath: filePathOf(head),
      line: lineOf(head),
      events: group,
    })
  }
  // Stable bucket order: most recent head event first.
  buckets.sort((a, b) => (b.events[0]?.tsMs ?? 0) - (a.events[0]?.tsMs ?? 0))
  return buckets
}

function lineOf(event: KeeperTraceEvent): number | null {
  if (event.source === 'anchored-thread') return event.line
  if (event.source === 'activity-event') return event.line
  if (event.source === 'decision-log') return event.line ?? null
  if (event.source === 'runtime-hop') return event.line ?? null
  return null
}

function filePathOf(event: KeeperTraceEvent): string | null {
  if (event.source === 'anchored-thread') return event.filePath ?? null
  if (event.source === 'activity-event') return event.filePath
  if (event.source === 'decision-log') return event.filePath ?? null
  if (event.source === 'runtime-hop') return event.filePath ?? null
  return null
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

function useReplayUntilMs(): number | null {
  const [untilMs, setUntilMs] = useState(ideReplayUntilMs.value)
  useEffect(() => ideReplayUntilMs.subscribe(value => setUntilMs(value)), [])
  return untilMs
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
  listStyle: 'none',
  margin: 0,
  padding: 0,
} as const

const CHIP_STYLE = {
  display: 'inline-block',
  width: '8px',
  height: '8px',
  padding: 0,
  borderRadius: '50%',
  border: '1px solid var(--color-bg-surface)',
  appearance: 'none',
  cursor: 'pointer',
} as const

const OVERFLOW_STYLE = {
  marginLeft: '4px',
  color: 'var(--color-fg-muted)',
  fontSize: 'var(--fs-11)',
} as const

const ROUTE_LINKS_STYLE = {
  display: 'inline-flex',
  minWidth: 0,
  flexWrap: 'wrap',
  alignItems: 'center',
  gap: '3px',
} as const

const CONTEXT_BADGE_STYLE = {
  minWidth: '34px',
  height: '17px',
  padding: '0 5px',
  border: '1px solid var(--color-border-muted)',
  borderRadius: 'var(--r-1)',
  background: 'var(--color-bg-subtle)',
  color: 'var(--color-fg-muted)',
  fontFamily: 'var(--font-mono)',
  fontSize: 'var(--fs-9)',
  lineHeight: '15px',
  whiteSpace: 'nowrap',
} as const

const ROUTE_LINK_BUTTON_STYLE = {
  minWidth: 0,
  maxWidth: '58px',
  height: '17px',
  padding: '0 5px',
  overflow: 'hidden',
  border: '1px solid var(--color-border-default)',
  borderRadius: 'var(--r-1)',
  background: 'var(--color-bg-page)',
  color: 'var(--color-fg-muted)',
  cursor: 'pointer',
  fontFamily: 'var(--font-mono)',
  fontSize: 'var(--fs-9)',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
} as const

function formatTooltip(event: KeeperTraceEvent): string {
  const sourceLabel = SOURCE_LABELS[event.source]
  const line = lineOf(event)
  const lineSuffix = line !== null
    ? ` L${line}`
    : ''
  const countSuffix = event.count > 1 ? ` ×${event.count}` : ''
  return `${sourceLabel}${lineSuffix}${countSuffix}`
}

export function OverlayKeeperTrace({ active, keeperFilter }: OverlayKeeperTraceProps) {
  const events = useTraceEvents()
  const replayUntilMs = useReplayUntilMs()
  if (!active) return null

  const replayFiltered = filterTraceEventsByReplay(events, replayUntilMs)
  const filtered = keeperFilter
    ? replayFiltered.filter(e => e.keeperName === keeperFilter)
    : replayFiltered
  if (filtered.length === 0) return null

  const buckets = bucketTraceEvents(filtered)
  if (buckets.length === 0) return null

  return html`
    <div
      class="ide-keeper-trace-overlay v2-ide-panel"
      role="region"
      aria-label="Keeper trace overlay"
      data-overlay="keeper-trace"
      style=${OVERLAY_CONTAINER_STYLE}
    >
      ${buckets.map(bucket => html`
        <${BucketRow}
          key=${`${bucket.keeperName}@${bucket.filePath ?? 'no-file'}@${bucket.line ?? 'no-line'}`}
          bucket=${bucket}
        />
      `)}
    </div>
  `
}

function BucketRow({ bucket }: { readonly bucket: TraceBucket }) {
  const visible = bucket.events.slice(0, TRACE_CHIP_CAP)
  const overflow = bucket.events.length - visible.length
  const lineLabel = bucket.line !== null ? `L${bucket.line}` : '—'
  const routeLinks = traceRouteLinks(bucket.events)
  const routeSummary = traceRouteSummary(routeLinks)

  return html`
    <div
      class="ide-trace-bucket v2-ide-row"
      role="group"
      data-keeper=${bucket.keeperName}
      data-file=${bucket.filePath ?? 'no-file'}
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
            role="listitem"
            data-source=${event.source}
            data-count=${event.count}
            style=${{ display: 'inline-flex' }}
          >
            <button
              type="button"
              class="ide-trace-chip v2-ide-action"
              data-source=${event.source}
              data-count=${event.count}
              data-event-id=${event.id}
              aria-label=${`${formatTooltip(event)}; jump replay to event`}
              title=${formatTooltip(event)}
              onClick=${() => selectTraceEvent(event)}
              style=${{ ...CHIP_STYLE, background: SOURCE_COLORS[event.source] }}
            />
          </li>
        `)}
      </ul>
      ${overflow > 0
        ? html`<span aria-label=${`${overflow} more`} data-overflow=${overflow} style=${OVERFLOW_STYLE}>+${overflow}</span>`
        : null}
      ${routeLinks.length > 0 ? html`
        <span
          class="ide-trace-context-badge"
          data-context-route-count=${routeLinks.length}
          title=${routeSummary}
          aria-label=${`${bucket.keeperName} trace has ${routeLinks.length} linked context routes: ${routeLinkLabels(routeLinks)}`}
          style=${CONTEXT_BADGE_STYLE}
        >
          CTX ${routeLinks.length}
        </span>
        <div class="ide-trace-route-links" aria-label=${`${bucket.keeperName} trace route links`} style=${ROUTE_LINKS_STYLE}>
          ${routeLinks.map(link => html`
            <button
              key=${link.id}
              type="button"
              class="ide-trace-route-link v2-ide-action"
              title=${link.evidence}
              aria-label=${`Open ${link.evidence}`}
              onClick=${() => openIdeContextRouteLink(link)}
              style=${ROUTE_LINK_BUTTON_STYLE}
            >
              ${link.label}
            </button>
          `)}
        </div>
      ` : null}
    </div>
  `
}


function traceRouteSummary(routeLinks: ReadonlyArray<IdeContextRouteLink>): string {
  return `Linked context: ${routeLinkLabels(routeLinks)}`
}

function selectTraceEvent(event: KeeperTraceEvent): void {
  setIdeReplayUntilMs(event.tsMs)
  const context = traceRouteContext(event)
  if (!context.filePath) return
  focusIdeContextAnchor({
    file_path: context.filePath,
    line: context.line,
    surface: context.surface ?? SOURCE_LABELS[event.source],
    label: context.label ?? formatTooltip(event),
    source_id: context.sourceId ?? `trace:${event.id}`,
    keeper_id: context.keeperId,
    route_links: routeLinksForContext(context),
  })
}

function traceRouteLinks(events: ReadonlyArray<KeeperTraceEvent>): ReadonlyArray<IdeContextRouteLink> {
  const links: IdeContextRouteLink[] = []
  const seen = new Set<string>()
  for (const event of events) {
    for (const link of routeLinksForContext(traceRouteContext(event))) {
      if (seen.has(link.id)) continue
      seen.add(link.id)
      links.push(link)
      if (links.length >= TRACE_ROUTE_LINK_CAP) return links
    }
  }
  return links
}

function traceRouteContext(event: KeeperTraceEvent): IdeContextRouteContext {
  if (event.source === 'activity-event') {
    return {
      filePath: event.filePath,
      line: event.line,
      surface: event.surface,
      label: `${event.surface} activity ${event.eventId}`,
      sourceId: `trace:${event.id}`,
      goalId: event.goalId,
      taskId: event.taskId,
      boardPostId: event.boardPostId,
      commentId: event.commentId,
      prId: event.prId,
      gitRef: event.gitRef,
      logId: event.logId,
      sessionId: event.sessionId,
      operationId: event.operationId,
      workerRunId: event.workerRunId,
      telemetryQuery: event.logId ?? event.eventId,
      keeperId: event.keeperName,
      telemetry: true,
    }
  }

  if (event.source === 'anchored-thread') {
    return {
      filePath: event.filePath ?? undefined,
      line: event.line ?? undefined,
      surface: 'Thread',
      label: `thread ${event.threadId}`,
      sourceId: `trace:${event.id}`,
      boardPostId: event.threadId,
      keeperId: event.keeperName,
    }
  }

  if (event.source === 'decision-log') {
    return {
      filePath: event.filePath,
      line: event.line,
      surface: 'Decision',
      label: decisionTraceLabel(event),
      sourceId: `trace:${event.id}`,
      goalId: event.goalId,
      taskId: event.taskId,
      boardPostId: event.boardPostId,
      commentId: event.commentId,
      prId: event.prId,
      gitRef: event.gitRef,
      logId: event.logId,
      sessionId: event.sessionId,
      operationId: event.operationId,
      workerRunId: event.workerRunId,
      keeperId: event.keeperName,
      telemetryQuery: event.logId ?? event.decisionId,
      telemetry: true,
    }
  }

  return {
    filePath: event.filePath,
    line: event.line,
    surface: 'Runtime',
    label: event.provider,
    sourceId: `trace:${event.id}`,
    goalId: event.goalId,
    taskId: event.taskId,
    boardPostId: event.boardPostId,
    commentId: event.commentId,
    prId: event.prId,
    gitRef: event.gitRef,
    logId: event.logId,
    sessionId: event.sessionId,
    operationId: event.operationId,
    workerRunId: event.workerRunId,
    keeperId: event.keeperName,
    telemetryQuery: event.logId ?? event.hopId,
    telemetry: true,
  }
}

function decisionTraceLabel(event: Extract<KeeperTraceEvent, { source: 'decision-log' }>): string {
  const choice = event.decisionChoice?.trim()
  const reason = event.decisionReason?.trim()
  const outcome = event.semanticOutcome?.trim()
  if (choice && reason) return `${choice}: ${reason}`
  if (choice) return choice
  if (reason) return reason
  if (outcome) return outcome
  return '(unknown outcome)'
}
