import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import { KeeperBadge } from '../keeper-badge'
import {
  createRunActivityStore,
  type RunActivityEvent,
  type RunActivityVerb,
} from './run-activity-store'

const FALLBACK_VERB_MAP: Readonly<Record<string, RunActivityVerb>> = {
  approved: 'approved',
  committed: 'committed',
  flagged: 'flagged',
}
const DEFAULT_VERB: RunActivityVerb = 'noted'

interface ApiActivityEvent {
  readonly seq: number
  readonly ts_ms: number
  readonly ts_iso: string
  readonly room_id: string
  readonly kind: string
  readonly actor?: { readonly kind: string; readonly id: string } | null
  readonly subject?: { readonly kind: string; readonly id: string } | null
  readonly payload?: unknown
  readonly tags?: ReadonlyArray<string>
}

interface ApiActivityResponse {
  readonly events?: ReadonlyArray<ApiActivityEvent>
  readonly latest_seq?: number
}

const EMPTY_ACTIVITY: ReadonlyArray<RunActivityEvent> = []

const DEFAULT_ROOM_ID = 'run-default'

function verbFromKind(kind: string): RunActivityVerb {
  const tail = kind.includes(".") ? kind.slice(kind.lastIndexOf(".") + 1) : kind
  return FALLBACK_VERB_MAP[tail] ?? DEFAULT_VERB
}

function targetFromSubject(subject: ApiActivityEvent['subject']): string {
  if (!subject) return ''
  return `${subject.kind}:${subject.id}`
}

function detailFromPayload(payload: unknown, kind: string): string | undefined {
  if (typeof payload === 'object' && payload !== null && !Array.isArray(payload)) {
    const record = payload as Record<string, unknown>
    const summary = record['summary'] ?? record['title'] ?? record['body'] ?? record['reason']
    if (typeof summary === 'string' && summary.trim() !== '') {
      const truncated = summary.length > 120 ? summary.slice(0, 117) + '...' : summary
      return truncated
    }
  }
  return kind
}

function mapApiEvent(event: ApiActivityEvent, roomId: string): RunActivityEvent {
  return {
    id: `evt-${event.seq}`,
    run_id: roomId,
    timestamp_ms: event.ts_ms,
    keeper_id: event.actor?.id ?? 'system',
    verb: verbFromKind(event.kind),
    target: targetFromSubject(event.subject),
    detail: detailFromPayload(event.payload, event.kind),
  }
}

async function fetchActivityEvents(): Promise<{ events: ReadonlyArray<RunActivityEvent>; roomId: string }> {
  try {
    const res = await fetch('/api/v1/activity/events?limit=50')
    if (!res.ok) return { events: EMPTY_ACTIVITY, roomId: DEFAULT_ROOM_ID }
    const data: ApiActivityResponse = await res.json()
    const rawEvents = data.events
    if (!Array.isArray(rawEvents) || rawEvents.length === 0) {
      return { events: EMPTY_ACTIVITY, roomId: DEFAULT_ROOM_ID }
    }
    const roomId = rawEvents[0].room_id || DEFAULT_ROOM_ID
    const mapped = rawEvents.map(e => mapApiEvent(e, roomId))
    return { events: mapped, roomId }
  } catch {
    return { events: EMPTY_ACTIVITY, roomId: DEFAULT_ROOM_ID }
  }
}

export function IdeActivityMock() {
  const store = useMemo(() => {
    const store = createRunActivityStore(DEFAULT_ROOM_ID)
    store.seed(EMPTY_ACTIVITY)
    return store
  }, [])
  const [, forceRender] = useState(0)

  useEffect(() => {
    let cancelled = false
    fetchActivityEvents().then(({ events, roomId }) => {
      if (cancelled) return
      store.reset(roomId)
      store.seed(events)
    })
    return () => { cancelled = true }
  }, [store])

  useEffect(() => store.subscribe(() => forceRender(tick => tick + 1)), [store])

  const events = store.events()
  const keepers = store.knownKeepers()

  return html`
    <div
      class="ide-rail-panel ide-activity-panel"
      role="region"
      aria-label="EVENT TIMELINE"
    >
      <div
        class="ide-rail-head"
      >
        <span>EVENT TIMELINE</span>
        <span>${events.length} events · ${keepers.length} keepers</span>
      </div>
      <ol
        class="ide-rail-list ide-activity-list"
      >
        ${events.length === 0
          ? html`<li class="ide-rail-empty">no recent activity</li>`
          : events.map(item => ActivityRow(item))}
      </ol>
    </div>
  `
}

function ActivityRow(item: RunActivityEvent) {
  const hue = keeperHueIndex(item.keeper_id)
  const dot = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  return html`
    <li
      class="ide-activity-row"
      style=${{
        '--ide-activity-dot': dot,
      }}
    >
      <span class="ide-activity-time">${formatActivityTime(item.timestamp_ms)}</span>
      <span class="ide-activity-dot" aria-hidden="true" />
      <div style=${{ display: 'flex', flexDirection: 'column', gap: '2px' }}>
        <span style=${{ fontSize: 'var(--fs-11)' }}>
          <${KeeperBadge} id=${item.keeper_id} variant="full" size="sm" />
          ${' '}${item.verb}${' '}<span style=${{ color: 'var(--color-fg-muted)' }}>${item.target}</span>
        </span>
        ${item.detail ? html`<span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${item.detail}</span>` : null}
      </div>
    </li>
  `
}

function formatActivityTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 19)
}
