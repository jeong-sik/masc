import { html } from 'htm/preact'

export type TelemetryView = 'cost' | 'audit'

export const TELEMETRY_VIEW_CHIPS: ReadonlyArray<{ key: TelemetryView; label: string }> = [
  { key: 'cost', label: '비용 / 지연' },
  { key: 'audit', label: '감사' },
]

const TELEMETRY_VIEW_SET: ReadonlySet<TelemetryView> = new Set<TelemetryView>(
  TELEMETRY_VIEW_CHIPS.map(chip => chip.key),
)

export function isTelemetryView(view: string): view is TelemetryView {
  return TELEMETRY_VIEW_SET.has(view as TelemetryView)
}

export function TelemetryPanel({ view }: { view: TelemetryView }) {
  return html`
    <div class="rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 text-xs text-[var(--color-fg-muted)]" data-testid="telemetry-panel" data-view=${view}>
      ${view === 'cost' ? '비용 및 지연 지표는 Runtime Efficiency 뷰로 통합됩니다.' : '감사 이벤트 요약은 Logs 및 Runtime 뷰로 통합됩니다.'}
    </div>
  `
}
