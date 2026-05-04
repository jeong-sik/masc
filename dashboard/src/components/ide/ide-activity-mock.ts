import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  createRunActivityStore,
  type RunActivityEvent,
  type RunActivityVerb,
} from './run-activity-store'

const KIND_TO_VERB: Readonly<Record<string, RunActivityVerb>> = {
  'task.created': 'noted',
  'task.claimed': 'flagged',
  'task.started': 'edited',
  'task.released': 'noted',
  'task.done': 'committed',
  'task.cancelled': 'noted',
  'task.submit_for_verification': 'noted',
  'task.approved': 'approved',
  'task.rejected': 'flagged',
  'task.linked': 'noted',
  'message.broadcast': 'commented on',
  'message.mentioned': 'asked on',
  'board.posted': 'noted',
  'board.commented': 'commented on',
  'board.voted': 'noted',
  'board.deleted': 'noted',
  'keeper.turn_completed': 'committed',
  'keeper.contract_verdict': 'noted',
  'keeper.friction': 'flagged',
  'keeper.operator_broadcast_required': 'asked on',
  'episode.flush': 'noted',
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
  return KIND_TO_VERB[kind] ?? DEFAULT_VERB
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
      role="region"
      aria-label="ACTIVITY"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--color-bg-surface)',
        borderLeft: '1px solid var(--color-border-default)',
        borderTop: '1px solid var(--color-border-divider)',
        minHeight: 0,
      }}
    >
      <div
        style=${{
          display: 'flex',
          justifyContent: 'space-between',
          padding: 'var(--sp-2) var(--sp-3)',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
          borderBottom: '1px solid var(--color-border-divider)',
        }}
      >
        <span>ACTIVITY</span>
        <span>${events.length} events · ${keepers.length} keepers</span>
      </div>
      <ol
        style=${{
          listStyle: 'none',
          padding: 'var(--sp-2)',
          margin: 0,
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--sp-1)',
          overflow: 'auto',
        }}
      >
        ${events.map(item => ActivityRow(item))}
      </ol>
    </div>
  `
}

function ActivityRow(item: RunActivityEvent) {
  const hue = keeperHueIndex(item.keeper_id)
  const dot = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  return html`
    <li
      style=${{
        display: 'grid',
        gridTemplateColumns: '52px 8px 1fr',
        gap: 'var(--sp-2)',
        alignItems: 'baseline',
        padding: '4px 6px',
        font: 'var(--type-body)',
        color: 'var(--color-fg-secondary)',
      }}
    >
      <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${formatActivityTime(item.timestamp_ms)}</span>
      <span aria-hidden="true" style=${{ width: '6px', height: '6px', borderRadius: '50%', background: dot, alignSelf: 'center' }} />
      <div style=${{ display: 'flex', flexDirection: 'column', gap: '2px' }}>
        <span style=${{ fontSize: 'var(--fs-11)' }}>
          <strong style=${{ color: dot }}>${item.keeper_id}</strong> ${' '}${item.verb}${' '}<span style=${{ color: 'var(--color-fg-muted)' }}>${item.target}</span>
        </span>
        ${item.detail ? html`<span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${item.detail}</span>` : null}
      </div>
    </li>
  `
}

function formatActivityTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 19)
}
