// AgentCoreHealthChip — global Agent Core runtime telemetry summary.
// Consumes agentCoreHealthSummary computed signal (previously dead).

import { html } from 'htm/preact'
import { useComputed, useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { agentCoreHealthSummary, agentCoreAgentEvents } from '../store'
import { ensureAgentCoreRuntimeReplay, loadMoreAgentCoreEvents } from '../agent-core-runtime-store'
import { SectionCard } from './common/card'
import { StatTile } from './common/stat-tile'
import { EmptyState } from './common/feedback-state'
import { formatRelativeAgeMs } from '../lib/format-time'
import { AGENT_CORE_OPENTELEMETRY_UI_URL } from '../config/constants'
import type { AgentCoreAgentEvent, AgentCoreHealthSummary } from '../types/agent-core'

function formatLastTick(tick: number | null): string {
  if (tick == null) return '—'
  return formatRelativeAgeMs(Date.now() - tick)
}

const EVENT_TYPE_LABELS: Record<AgentCoreAgentEvent['type'], string> = {
  keeper_lifecycle: '생명주기',
}

/** Render an AgentCoreAgentEvent into a single-line summary.
 *  Exposed for unit testing. */
function describeAgentEvent(evt: AgentCoreAgentEvent): string {
  const label = EVENT_TYPE_LABELS[evt.type]
  switch (evt.type) {
    case 'keeper_lifecycle': {
      const detail = evt.event ?? evt.phase ?? evt.detail
      return `${label}${detail ? ` · ${detail}` : ''}`
    }
  }
}

function describeTotalEventsDetail(summary: Pick<AgentCoreHealthSummary,
  'replayLoadedEvents' | 'replayTotalMatchingEvents' | 'replayTruncated' | 'replayCapped'
>): string {
  if (summary.replayCapped) {
    return `최근 ${summary.replayLoadedEvents}개 표시 중 (서버 조회 한도)`
  }
  if (summary.replayTruncated) {
    return `최근 ${summary.replayLoadedEvents}개 표시 중 (전체 ${summary.replayTotalMatchingEvents})`
  }
  if (summary.replayLoadedEvents === 0 && summary.replayTotalMatchingEvents > 0) {
    return 'live only'
  }
  return 'durable replay + live'
}

function describeEvidenceDetail(summary: Pick<AgentCoreHealthSummary,
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

export function AgentCoreHealthChip() {
  const summary = useComputed(() => agentCoreHealthSummary.value)
  const recentEvents = useComputed(() => agentCoreAgentEvents.value.slice(0, 3))
  const isLoadingMore = useSignal(false)
  const replayError = useSignal<string | null>(null)

  useEffect(() => {
    let disposed = false
    replayError.value = null
    void ensureAgentCoreRuntimeReplay().catch(err => {
      if (disposed) return
      const message = err instanceof Error ? err.message : String(err)
      replayError.value = message
      console.warn('[Agent Core] runtime replay failed', message)
    })
    return () => {
      disposed = true
    }
  }, [])

  async function handleLoadMore() {
    if (isLoadingMore.value) return
    isLoadingMore.value = true
    try {
      await loadMoreAgentCoreEvents()
    } finally {
      isLoadingMore.value = false
    }
  }

  if (summary.value.replayTotalMatchingEvents === 0) {
    return html`
      <${SectionCard} label="Agent Core 런타임">
        <${EmptyState}
          message=${replayError.value
            ? `Agent Core 리플레이를 불러오지 못했습니다: ${replayError.value}`
            : '아직 Agent Core 이벤트가 수신되지 않았습니다.'}
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
    <${SectionCard} label="Agent Core 런타임">
      <div class="v2-shell-panel grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-2">
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
      </div>
      ${recentEvents.value.length > 0 ? html`
        <div class="v2-shell-detail mt-3 pt-3 border-t border-[var(--color-border-default)]">
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
        </div>
      ` : null}
      ${AGENT_CORE_OPENTELEMETRY_UI_URL ? html`<div class="mt-2 text-right">
        <a
          href=${AGENT_CORE_OPENTELEMETRY_UI_URL}
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
