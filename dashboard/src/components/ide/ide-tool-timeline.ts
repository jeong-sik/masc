import { html } from 'htm/preact'
import { useEffect, useState, useCallback } from 'preact/hooks'

interface ToolEvent {
  readonly type: 'tool'
  readonly tool_name: string
  readonly keeper_id: string
  readonly turn_id: string
  readonly outcome: string
  readonly typed_outcome: string
  readonly latency_ms: number
  readonly summary: string
  readonly file_path: string | null
  readonly timestamp_ms: number
}

interface PrEvent {
  readonly type: 'pr'
  readonly pr_number: number
  readonly pr_url: string
  readonly pr_title: string
  readonly pr_state: string
  readonly repo: string
  readonly keeper_id: string
  readonly turn_id: string
  readonly comment_count: number
  readonly review_status: string | null
  readonly timestamp_ms: number
}

interface TurnEvent {
  readonly type: 'turn'
  readonly turn_id: string
  readonly keeper_id: string
  readonly phase: string
  readonly model_used: string | null
  readonly tools_used: ReadonlyArray<string>
  readonly stop_reason: string | null
  readonly duration_ms: number | null
  readonly timestamp_ms: number
}

type IdeEvent = ToolEvent | PrEvent | TurnEvent

interface EventsResponse {
  readonly events: ReadonlyArray<IdeEvent>
  readonly total: number
  readonly limit: number
}

interface IdeToolTimelineProps {
  readonly keeperName?: string | null
}

const OUTCOME_COLORS: Record<string, string> = {
  success: 'var(--tone-ok, #10b981)',
  failure: 'var(--tone-err, #ef4444)',
  progress: 'var(--tone-ok, #10b981)',
  no_progress: 'var(--tone-warn, #f59e0b)',
  error: 'var(--tone-err, #ef4444)',
}

const PR_STATE_COLORS: Record<string, string> = {
  open: 'var(--tone-info, #3b82f6)',
  merged: 'var(--tone-ok, #10b981)',
  closed: 'var(--tone-muted, #6b7280)',
}

function formatLatency(ms: number): string {
  if (ms < 1000) return `${ms}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

function formatTimestamp(ms: number): string {
  const date = new Date(ms)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffSec = Math.floor(diffMs / 1000)
  if (diffSec < 60) return `${diffSec}s ago`
  const diffMin = Math.floor(diffSec / 60)
  if (diffMin < 60) return `${diffMin}m ago`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}h ago`
  return date.toLocaleDateString()
}

function ToolEventCard({ event }: { event: ToolEvent }) {
  return html`
    <div class="ide-timeline__event ide-timeline__event--tool" data-outcome=${event.outcome}>
      <div class="ide-timeline__event-header">
        <span class="ide-timeline__tool-name">${event.tool_name}</span>
        <span
          class="ide-timeline__outcome"
          style=${{ color: OUTCOME_COLORS[event.typed_outcome] ?? 'inherit' }}
        >${event.typed_outcome}</span>
        <span class="ide-timeline__latency">${formatLatency(event.latency_ms)}</span>
        <span class="ide-timeline__time">${formatTimestamp(event.timestamp_ms)}</span>
      </div>
      ${event.summary
        ? html`<div class="ide-timeline__summary">${event.summary}</div>`
        : null}
      ${event.file_path
        ? html`<div class="ide-timeline__file">${event.file_path}</div>`
        : null}
    </div>
  `
}

function PrEventCard({ event }: { event: PrEvent }) {
  return html`
    <div class="ide-timeline__event ide-timeline__event--pr" data-state=${event.pr_state}>
      <div class="ide-timeline__event-header">
        <span class="ide-timeline__pr-badge">PR</span>
        <span
          class="ide-timeline__pr-state"
          style=${{ color: PR_STATE_COLORS[event.pr_state] ?? 'inherit' }}
        >${event.pr_state}</span>
        <a
          class="ide-timeline__pr-link"
          href=${event.pr_url}
          target="_blank"
          rel="noopener"
        >#${event.pr_number}</a>
        <span class="ide-timeline__time">${formatTimestamp(event.timestamp_ms)}</span>
      </div>
      <div class="ide-timeline__pr-title">${event.pr_title}</div>
      <div class="ide-timeline__pr-meta">
        <span class="ide-timeline__repo">${event.repo}</span>
        ${event.comment_count > 0
          ? html`<span class="ide-timeline__comments">${event.comment_count} comments</span>`
          : null}
      </div>
    </div>
  `
}

function TurnEventCard({ event }: { event: TurnEvent }) {
  return html`
    <div class="ide-timeline__event ide-timeline__event--turn" data-phase=${event.phase}>
      <div class="ide-timeline__event-header">
        <span class="ide-timeline__turn-badge">Turn</span>
        <span class="ide-timeline__phase">${event.phase}</span>
        ${event.model_used
          ? html`<span class="ide-timeline__model">${event.model_used}</span>`
          : null}
        ${event.duration_ms != null
          ? html`<span class="ide-timeline__duration">${formatLatency(event.duration_ms)}</span>`
          : null}
        <span class="ide-timeline__time">${formatTimestamp(event.timestamp_ms)}</span>
      </div>
      ${event.tools_used.length > 0
        ? html`<div class="ide-timeline__tools-used">
            ${event.tools_used.map(t => html`<span class="ide-timeline__tool-chip">${t}</span>`)}
          </div>`
        : null}
      ${event.stop_reason
        ? html`<div class="ide-timeline__stop-reason">${event.stop_reason}</div>`
        : null}
    </div>
  `
}

function EventCard({ event }: { event: IdeEvent }) {
  switch (event.type) {
    case 'tool': return html`<${ToolEventCard} event=${event} />`
    case 'pr': return html`<${PrEventCard} event=${event} />`
    case 'turn': return html`<${TurnEventCard} event=${event} />`
    default: return null
  }
}

export function IdeToolTimeline({ keeperName }: IdeToolTimelineProps) {
  const [events, setEvents] = useState<ReadonlyArray<IdeEvent>>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const fetchEvents = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const params = new URLSearchParams()
      if (keeperName) params.set('keeper_id', keeperName)
      params.set('limit', '50')
      const res = await fetch(`/api/v1/ide/events?${params}`)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data: EventsResponse = await res.json()
      setEvents(data.events)
      setTotal(data.total)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load')
    } finally {
      setLoading(false)
    }
  }, [keeperName])

  useEffect(() => {
    fetchEvents()
  }, [fetchEvents])

  return html`
    <div class="ide-timeline" data-testid="ide-tool-timeline">
      <div class="ide-timeline__header">
        <span class="ide-timeline__title">Activity</span>
        <span>
          <button
            class="ide-timeline__refresh"
            onClick=${fetchEvents}
            disabled=${loading}
            title="Refresh events"
          >↻</button>
          <span class="ide-timeline__count">${total}</span>
        </span>
      </div>
      ${loading
        ? html`<div class="ide-timeline__loading">Loading...</div>`
        : error
          ? html`<div class="ide-timeline__error">${error}</div>`
          : events.length === 0
            ? html`<div class="ide-timeline__empty">No activity yet</div>`
            : html`
              <div class="ide-timeline__list">
                ${events.map((event, i) => html`
                  <${EventCard} key=${i} event=${event} />
                `)}
              </div>
            `}
    </div>
  `
}
