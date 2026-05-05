// OasHealthChip — global OAS runtime telemetry summary.
// Consumes oasHealthSummary computed signal (previously dead).

import { html } from 'htm/preact'
import { useComputed } from '@preact/signals'
import { oasHealthSummary, oasAgentEvents, oasKeeperSnapshots } from '../store'
import { Card } from './common/card'
import { StatTile } from './common/stat-tile'
import { EmptyState } from './common/empty-state'
import type { OasAgentEvent, OasHealthSummary, OasKeeperSnapshot } from '../types/oas'

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
function describeAgentEvent(evt: OasAgentEvent): string {
  const label = EVENT_TYPE_LABELS[evt.type]
  switch (evt.type) {
    case 'selected':
      return `${label}${evt.trigger ? ` · ${evt.trigger}` : ''}`
    case 'decision': {
      const detail = evt.action ?? evt.trigger_reason
      return `${label}${detail ? ` · ${detail}` : ''}`
    }
    case 'action_executed':
      return `${label}${evt.action ? ` · ${evt.action}` : ''}`
    case 'keeper_lifecycle': {
      const detail = evt.event ?? evt.phase ?? evt.detail
      return `${label}${detail ? ` · ${detail}` : ''}`
    }
    case 'trust_updated':
      return `${label}${evt.trust_score != null ? ` · ${evt.trust_score.toFixed(2)}` : ''}${evt.secondary_agent ? ` → ${evt.secondary_agent}` : ''}`
    case 'reputation_changed': {
      const summary =
        evt.old_score != null && evt.new_score != null
          ? `${evt.old_score.toFixed(2)} → ${evt.new_score.toFixed(2)}`
          : evt.trend
      return `${label}${summary ? ` · ${summary}` : ''}`
    }
  }
}

/** Pick the N most recently updated keepers from a snapshot map.
 *  Exposed for unit testing. */
function topKeepers(
  snapshots: Map<string, OasKeeperSnapshot>,
  limit: number,
): OasKeeperSnapshot[] {
  return Array.from(snapshots.values())
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, limit)
}

function describeTotalEventsDetail(summary: Pick<OasHealthSummary,
  'replayLoadedEvents' | 'replayTotalMatchingEvents' | 'replayTruncated' | 'totalEvents'
>): string {
  if (summary.replayTruncated) {
    return `replay ${summary.replayLoadedEvents}/${summary.replayTotalMatchingEvents} + live`
  }
  if (summary.replayLoadedEvents === 0 && summary.totalEvents > 0) {
    return 'live only'
  }
  return 'durable replay + live'
}

function describeSampleWindow(summary: Pick<OasHealthSummary,
  'replayLoadedEvents' | 'replayTotalMatchingEvents' | 'replayTruncated'
>): string | null {
  if (!summary.replayTruncated) return null
  return `sample ${summary.replayLoadedEvents}/${summary.replayTotalMatchingEvents}`
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
      <//>
    `
  }

  const sampleWindow = describeSampleWindow(summary.value)
  const llmDetail =
    summary.value.lastLlmCallTs != null
      ? `최근 ${formatLastTick(summary.value.lastLlmCallTs)}`
      : 'durable journal'
  const errorDetail =
    summary.value.lastErrorTs != null
      ? `최근 ${formatLastTick(summary.value.lastErrorTs)}`
      : 'Api/agent 실패'

  return html`
    <${Card} title="OAS 런타임">
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-2">
        <${StatTile}
          label="총 이벤트"
          value=${String(summary.value.totalEvents)}
          delta=${{ direction: 'flat', text: describeTotalEventsDetail(summary.value) }}
        />
        <${StatTile}
          label="LLM 호출"
          value=${String(summary.value.totalLlmCalls)}
          delta=${{ direction: 'up', text: sampleWindow ? `${llmDetail} · ${sampleWindow}` : llmDetail }}
        />
        <${StatTile}
          label="에러"
          value=${String(summary.value.totalErrors)}
          status=${summary.value.totalErrors > 0 ? 'crit' : undefined}
          delta=${{ direction: summary.value.totalErrors > 0 ? 'down' as const : 'flat' as const, text: sampleWindow ? `${errorDetail} · ${sampleWindow}` : errorDetail }}
        />
        <${StatTile}
          label="에이전트 이벤트"
          value=${String(summary.value.agentEventsCount)}
          delta=${{ direction: 'flat', text: '자율성 트레이스' }}
        />
        <${StatTile}
          label="Keeper 스냅샷"
          value=${String(summary.value.keeperSnapshotsCount)}
          status=${summary.value.keeperSnapshotsCount > 0 ? 'ok' : undefined}
          delta=${{ direction: summary.value.keeperSnapshotsCount > 0 ? 'up' as const : 'flat' as const, text: '활성 keeper' }}
        />
        <${StatTile}
          label="최근 tick"
          value=${formatLastTick(summary.value.lastKeeperTick)}
          status=${isStale.value ? 'warn' : 'ok'}
          delta=${{ direction: isStale.value ? 'down' as const : 'up' as const, text: isStale.value ? '신호 끊김' : '수신 중' }}
        />
      </div>
      ${recentEvents.value.length > 0 || recentKeepers.value.length > 0 ? html`
        <div class="mt-3 pt-3 border-t border-[var(--color-border-default)] grid md:grid-cols-2 gap-4">
          ${recentEvents.value.length > 0 ? html`
            <div>
              <div class="text-3xs text-[var(--color-fg-muted)] tracking-wider uppercase font-medium mb-2">
                최근 자율성 이벤트
              </div>
              <ul class="space-y-1">
                ${recentEvents.value.map(evt => html`
                  <li class="flex items-baseline justify-between gap-2 text-2xs">
                    <span class="text-[var(--color-fg-primary)] truncate">
                      <span class="font-mono text-[var(--color-fg-disabled)]">${evt.agent_name}</span>
                      <span class="text-[var(--color-fg-muted)]"> · </span>
                      ${describeAgentEvent(evt)}
                    </span>
                    <span class="text-[var(--color-fg-muted)] tabular-nums shrink-0">
                      ${formatLastTick(evt.timestamp * 1000)}
                    </span>
                  </li>
                `)}
              </ul>
            </div>
          ` : null}
          ${recentKeepers.value.length > 0 ? html`
            <div>
              <div class="text-3xs text-[var(--color-fg-muted)] tracking-wider uppercase font-medium mb-2">
                활성 Keeper
              </div>
              <ul class="space-y-1">
                ${recentKeepers.value.map(snap => html`
                  <li class="flex items-baseline justify-between gap-2 text-2xs">
                    <span class="text-[var(--color-fg-primary)] truncate">
                      <span class="font-mono text-[var(--color-fg-disabled)]">${snap.keeper_name}</span>
                      <span class="text-[var(--color-fg-muted)]"> · gen ${snap.generation} · ${Math.round(snap.context_ratio * 100)}%</span>
                    </span>
                    <span class="text-[var(--color-fg-muted)] tabular-nums shrink-0">
                      ${formatLastTick(snap.timestamp * 1000)}
                    </span>
                  </li>
                `)}
              </ul>
            </div>
          ` : null}
        </div>
      ` : null}
    <//>
  `
}
