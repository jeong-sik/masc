// OasHealthChip — global OAS runtime telemetry summary.
// Consumes oasHealthSummary computed signal (previously dead).

import { html } from 'htm/preact'
import { useComputed, useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { oasHealthSummary, oasAgentEvents, oasKeeperSnapshots } from '../store'
import { ensureOasRuntimeReplay, loadMoreOasEvents } from '../oas-runtime-store'
import { SectionCard } from './common/card'
import { StatTile } from './common/stat-tile'
import { EmptyState } from './common/feedback-state'
import { formatRelativeAgeMs } from '../lib/format-time'
import { OAS_OPENTELEMETRY_UI_URL } from '../config/constants'
import type { OasAgentEvent, OasHealthSummary, OasKeeperSnapshot } from '../types/oas'

const STALE_MS = 60_000

function formatLastTick(tick: number | null): string {
  if (tick == null) return '—'
  return formatRelativeAgeMs(Date.now() - tick)
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
  'replayLoadedEvents' | 'replayTotalMatchingEvents' | 'replayTruncated'
>): string {
  if (summary.replayTruncated) {
    return `최근 ${summary.replayLoadedEvents}개 표시 중 (전체 ${summary.replayTotalMatchingEvents})`
  }
  if (summary.replayLoadedEvents === 0 && summary.replayTotalMatchingEvents > 0) {
    return 'live only'
  }
  return 'durable replay + live'
}

function describeEvidenceDetail(summary: Pick<OasHealthSummary,
  | 'artifactRefsCount'
  | 'rawTraceRefsCount'
  | 'reportRefsCount'
  | 'proofRefsCount'
  | 'telemetryRefsCount'
  | 'runtimeEvidenceRefsCount'
>): string {
  const parts = [
    summary.rawTraceRefsCount > 0 ? `trace ${summary.rawTraceRefsCount}` : null,
    summary.reportRefsCount > 0 ? `report ${summary.reportRefsCount}` : null,
    summary.proofRefsCount > 0 ? `proof ${summary.proofRefsCount}` : null,
    summary.telemetryRefsCount > 0 ? `telemetry ${summary.telemetryRefsCount}` : null,
    summary.runtimeEvidenceRefsCount > 0 ? `evidence ${summary.runtimeEvidenceRefsCount}` : null,
    summary.artifactRefsCount > 0 ? `artifact ${summary.artifactRefsCount}` : null,
  ].filter((part): part is string => part !== null)
  return parts.length > 0 ? parts.slice(0, 3).join(' · ') : '증거 참조 없음'
}

export function OasHealthChip() {
  const summary = useComputed(() => oasHealthSummary.value)
  const recentEvents = useComputed(() => oasAgentEvents.value.slice(0, 3))
  const recentKeepers = useComputed(() => topKeepers(oasKeeperSnapshots.value, 3))
  const isStale = useComputed(() => {
    const tick = summary.value.lastKeeperTick
    return tick == null || Date.now() - tick > STALE_MS
  })
  const isLoadingMore = useSignal(false)
  const replayError = useSignal<string | null>(null)

  useEffect(() => {
    let disposed = false
    replayError.value = null
    void ensureOasRuntimeReplay().catch(err => {
      if (disposed) return
      const message = err instanceof Error ? err.message : String(err)
      replayError.value = message
      console.warn('[OAS] runtime replay failed', message)
    })
    return () => {
      disposed = true
    }
  }, [])

  async function handleLoadMore() {
    if (isLoadingMore.value) return
    isLoadingMore.value = true
    try {
      await loadMoreOasEvents()
    } finally {
      isLoadingMore.value = false
    }
  }

  if (summary.value.replayTotalMatchingEvents === 0) {
    return html`
      <${SectionCard} label="OAS 런타임">
        <${EmptyState}
          message=${replayError.value
            ? `OAS 리플레이를 불러오지 못했습니다: ${replayError.value}`
            : '아직 OAS 이벤트가 수신되지 않았습니다.'}
        />
      <//>
    `
  }

  const llmDetail =
    summary.value.lastLlmCallTs != null
      ? `최근 ${formatLastTick(summary.value.lastLlmCallTs)}`
      : 'durable journal'
  const errorDetail =
    summary.value.lastErrorTs != null
      ? `최근 ${formatLastTick(summary.value.lastErrorTs)}`
      : 'Api/agent 실패'
  const evidenceDetail =
    summary.value.lastEvidenceTs != null
      ? `${describeEvidenceDetail(summary.value)} · 최근 ${formatLastTick(summary.value.lastEvidenceTs)}`
      : describeEvidenceDetail(summary.value)

  return html`
    <${SectionCard} label="OAS 런타임">
      <div class="v2-shell-panel grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-2">
        ${replayError.value ? html`
          <${StatTile}
            label="Replay"
            value="실패"
            status="crit"
            delta=${{ direction: 'down', text: replayError.value }}
          />
        ` : null}
        <${StatTile}
          label="총 이벤트"
          value=${String(summary.value.replayTotalMatchingEvents)}
          delta=${{ direction: 'flat', text: describeTotalEventsDetail(summary.value) }}
        />
        <${StatTile}
          label="LLM 호출"
          value=${String(summary.value.totalLlmCalls)}
          delta=${{ direction: 'up', text: llmDetail }}
        />
        <${StatTile}
          label="에러"
          value=${String(summary.value.totalErrors)}
          status=${summary.value.totalErrors > 0 ? 'crit' : undefined}
          delta=${{ direction: summary.value.totalErrors > 0 ? 'down' as const : 'flat' as const, text: errorDetail }}
        />
        <${StatTile}
          label="증거 참조"
          value=${String(summary.value.evidenceRefsCount)}
          status=${summary.value.evidenceRefsCount > 0 ? 'ok' : 'warn'}
          delta=${{ direction: summary.value.evidenceRefsCount > 0 ? 'up' as const : 'flat' as const, text: evidenceDetail }}
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
        <div class="v2-shell-detail mt-3 pt-3 border-t border-[var(--color-border-default)] grid md:grid-cols-2 gap-4">
          ${recentEvents.value.length > 0 ? html`
            <div>
              <div class="text-3xs text-[var(--color-fg-muted)] tracking-wider uppercase font-medium mb-2">
                최근 자율성 이벤트
              </div>
              <ul class="space-y-1">
                ${recentEvents.value.map(evt => html`
                  <li class="v2-shell-row flex items-baseline justify-between gap-2 text-2xs">
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
              ${summary.value.hasMore ? html`
                <button
                  class="v2-shell-action mt-2 text-2xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] underline disabled:opacity-50"
                  onClick=${handleLoadMore}
                  disabled=${isLoadingMore.value}
                >
                  ${isLoadingMore.value ? '불러오는 중...' : '더 보기'}
                </button>
              ` : null}
            </div>
          ` : null}
          ${recentKeepers.value.length > 0 ? html`
            <div>
              <div class="text-3xs text-[var(--color-fg-muted)] tracking-wider uppercase font-medium mb-2">
                활성 Keeper
              </div>
              <ul class="space-y-1">
                ${recentKeepers.value.map(snap => html`
                  <li class="v2-shell-row flex items-baseline justify-between gap-2 text-2xs">
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
      ${OAS_OPENTELEMETRY_UI_URL ? html`<div class="mt-2 text-right">
        <a
          href=${OAS_OPENTELEMETRY_UI_URL}
          target="_blank"
          rel="noopener noreferrer"
          class="v2-shell-action v2-mobile-operator-target inline-flex items-center text-3xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] underline"
        >
          OpenTelemetry에서 보기 →
        </a>
      </div>` : null}
    <//>
  `
}
