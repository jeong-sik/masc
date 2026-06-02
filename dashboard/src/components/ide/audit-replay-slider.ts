import { html } from 'htm/preact'
import { Slider } from '../common/slider'

export interface AuditReplayEvent {
  readonly id: string
  readonly timestamp_ms: number
}

export interface AuditReplayBounds {
  readonly min: number
  readonly max: number
  readonly count: number
}

export function auditReplayBounds(
  events: ReadonlyArray<AuditReplayEvent>,
): AuditReplayBounds | null {
  let min = Number.POSITIVE_INFINITY
  let max = Number.NEGATIVE_INFINITY
  let count = 0
  for (const event of events) {
    if (!Number.isFinite(event.timestamp_ms)) continue
    min = Math.min(min, event.timestamp_ms)
    max = Math.max(max, event.timestamp_ms)
    count += 1
  }
  return count === 0 ? null : { min, max, count }
}

export function filterReplayEvents<T extends AuditReplayEvent>(
  events: ReadonlyArray<T>,
  untilMs: number | null,
): T[] {
  if (untilMs === null || !Number.isFinite(untilMs)) return [...events]
  return events.filter(event => Number.isFinite(event.timestamp_ms) && event.timestamp_ms <= untilMs)
}

export function formatReplayTime(ms: number | null): string {
  if (ms === null || !Number.isFinite(ms)) return '--:--:--'
  return new Date(ms).toISOString().slice(11, 19)
}

export function AuditReplaySlider({
  events,
  value,
  onChange,
}: {
  readonly events: ReadonlyArray<AuditReplayEvent>
  readonly value: number | null
  readonly onChange: (untilMs: number | null) => void
}) {
  const bounds = auditReplayBounds(events)
  const canScrub = bounds !== null && bounds.max > bounds.min
  const current = bounds === null
    ? null
    : value === null || !Number.isFinite(value)
      ? bounds.max
      : Math.max(bounds.min, Math.min(bounds.max, value))
  const visibleCount = filterReplayEvents(events, current).length

  return html`
    <div
      data-testid="audit-replay-slider"
      style=${{
        display: 'grid',
        gridTemplateColumns: 'auto minmax(96px, 1fr) auto',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        color: 'var(--color-fg-muted)',
        fontSize: 'var(--fs-11)',
      }}
    >
      <span style=${{ font: 'var(--type-eyebrow)', color: 'var(--color-fg-secondary)' }}>REPLAY</span>
      <${Slider}
        min=${canScrub ? bounds!.min : 0}
        max=${canScrub ? bounds!.max : 1}
        step=${1}
        value=${canScrub ? current! : 0}
        disabled=${!canScrub}
        aria-label="Audit replay timestamp"
        onChange=${(next: number) => onChange(next)}
      />
      <span style=${{ fontFamily: 'var(--font-mono)', color: 'var(--color-fg-secondary)', whiteSpace: 'nowrap' }}>
        ${visibleCount}/${bounds?.count ?? 0} | ${formatReplayTime(current)}
      </span>
    </div>
  `
}
