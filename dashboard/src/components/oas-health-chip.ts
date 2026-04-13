// OasHealthChip — global OAS runtime telemetry summary.
// Consumes oasHealthSummary computed signal (previously dead).

import { html } from 'htm/preact'
import { useComputed } from '@preact/signals'
import { oasHealthSummary } from '../store'
import { Card } from './common/card'
import { StatCell } from './common/stat-cell'
import { EmptyState } from './common/empty-state'

const STALE_MS = 60_000

function formatLastTick(tick: number | null): string {
  if (tick == null) return '—'
  const delta = Date.now() - tick
  if (delta < 1000) return '방금'
  if (delta < 60_000) return `${Math.floor(delta / 1000)}초 전`
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)}분 전`
  return `${Math.floor(delta / 3_600_000)}시간 전`
}

export function OasHealthChip() {
  const summary = useComputed(() => oasHealthSummary.value)
  const isStale = useComputed(() => {
    const tick = summary.value.lastKeeperTick
    return tick == null || Date.now() - tick > STALE_MS
  })

  if (summary.value.totalEvents === 0) {
    return html`
      <${Card} title="OAS 런타임">
        <${EmptyState} message="아직 OAS 이벤트가 수신되지 않았습니다." />
      </${Card}>
    `
  }

  return html`
    <${Card} title="OAS 런타임">
      <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
        <${StatCell}
          label="총 이벤트"
          value=${summary.value.totalEvents}
          detail="SSE relay"
        />
        <${StatCell}
          label="에이전트 이벤트"
          value=${summary.value.agentEventsCount}
          detail="자율성 트레이스"
        />
        <${StatCell}
          label="Keeper 스냅샷"
          value=${summary.value.keeperSnapshotsCount}
          detail="활성 keeper"
        />
        <${StatCell}
          label="최근 tick"
          value=${formatLastTick(summary.value.lastKeeperTick)}
          detail=${isStale.value ? '신호 끊김' : '수신 중'}
          tone=${isStale.value ? 'text-[var(--warn)]' : 'text-[var(--ok)]'}
        />
      </div>
    </${Card}>
  `
}
