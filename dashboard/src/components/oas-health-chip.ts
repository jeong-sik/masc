// OasHealthChip — global OAS runtime telemetry summary.
// Consumes oasHealthSummary computed signal (previously dead).

import { html } from 'htm/preact'
import { useComputed } from '@preact/signals'
import { oasHealthSummary, oasAgentEvents, oasKeeperSnapshots } from '../store'
import { Card } from './common/card'
import { StatCell } from './common/stat-cell'
import { EmptyState } from './common/empty-state'
import type { OasAgentEvent, OasKeeperSnapshot } from '../types/oas'

const STALE_MS = 60_000

function formatLastTick(tick: number | null): string {
  if (tick == null) return '—'
  const delta = Date.now() - tick
  if (delta < 1000) return '방금'
  if (delta < 60_000) return `${Math.floor(delta / 1000)}초 전`
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)}분 전`
  return `${Math.floor(delta / 3_600_000)}시간 전`
}

const EVENT_TYPE_LABELS: Record<OasAgentEvent['type'], string> = {
  selected: '선택',
  decision: '결정',
  action_executed: '실행',
  keeper_lifecycle: '생명주기',
  trust_updated: '신뢰도',
  reputation_changed: '평판',
}

/** Render an OasAgentEvent into a single-line summary.
 *  Exposed for unit testing. */
export function describeAgentEvent(evt: OasAgentEvent): string {
  const label = EVENT_TYPE_LABELS[evt.type]
  const action = evt.action ?? evt.event ?? evt.trigger
  const target = evt.secondary_agent ? ` → ${evt.secondary_agent}` : ''
  return `${label}${action ? ` · ${action}` : ''}${target}`
}

/** Pick the N most recently updated keepers from a snapshot map.
 *  Exposed for unit testing. */
export function topKeepers(
  snapshots: Map<string, OasKeeperSnapshot>,
  limit: number,
): OasKeeperSnapshot[] {
  return Array.from(snapshots.values())
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, limit)
}

export function OasHealthChip() {
  const summary = useComputed(() => oasHealthSummary.value)
  const recentEvents = useComputed(() => oasAgentEvents.value.slice(0, 3))
  const recentKeepers = useComputed(() => topKeepers(oasKeeperSnapshots.value, 3))
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
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-2">
        <${StatCell}
          label="총 이벤트"
          value=${summary.value.totalEvents}
          detail="live tracked"
        />
        <${StatCell}
          label="LLM 호출"
          value=${summary.value.totalLlmCalls}
          detail=${summary.value.lastLlmCallTs != null
            ? `최근 ${formatLastTick(summary.value.lastLlmCallTs)}`
            : 'durable journal'}
        />
        <${StatCell}
          label="에러"
          value=${summary.value.totalErrors}
          detail=${summary.value.lastErrorTs != null
            ? `최근 ${formatLastTick(summary.value.lastErrorTs)}`
            : 'Api/agent 실패'}
          tone=${summary.value.totalErrors > 0 ? 'text-[var(--bad)]' : undefined}
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
      ${recentEvents.value.length > 0 || recentKeepers.value.length > 0 ? html`
        <div class="mt-3 pt-3 border-t border-[var(--white-6)] grid md:grid-cols-2 gap-4">
          ${recentEvents.value.length > 0 ? html`
            <div>
              <div class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium mb-2">
                최근 자율성 이벤트
              </div>
              <ul class="space-y-1">
                ${recentEvents.value.map(evt => html`
                  <li class="flex items-baseline justify-between gap-2 text-[11px]">
                    <span class="text-[var(--text-body)] truncate">
                      <span class="font-mono text-[var(--text-dim)]">${evt.agent_name}</span>
                      <span class="text-[var(--text-muted)]"> · </span>
                      ${describeAgentEvent(evt)}
                    </span>
                    <span class="text-[var(--text-muted)] tabular-nums shrink-0">
                      ${formatLastTick(evt.timestamp * 1000)}
                    </span>
                  </li>
                `)}
              </ul>
            </div>
          ` : null}
          ${recentKeepers.value.length > 0 ? html`
            <div>
              <div class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium mb-2">
                활성 Keeper
              </div>
              <ul class="space-y-1">
                ${recentKeepers.value.map(snap => html`
                  <li class="flex items-baseline justify-between gap-2 text-[11px]">
                    <span class="text-[var(--text-body)] truncate">
                      <span class="font-mono text-[var(--text-dim)]">${snap.keeper_name}</span>
                      <span class="text-[var(--text-muted)]"> · gen ${snap.generation} · ${Math.round(snap.context_ratio * 100)}%</span>
                    </span>
                    <span class="text-[var(--text-muted)] tabular-nums shrink-0">
                      ${formatLastTick(snap.timestamp * 1000)}
                    </span>
                  </li>
                `)}
              </ul>
            </div>
          ` : null}
        </div>
      ` : null}
    </${Card}>
  `
}
