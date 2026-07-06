// Session trace view — main container for GitHub Agents-style activity trace.
// Each instance reads state by its own agentName prop, avoiding global state corruption
// when multiple overlays are open simultaneously.

import { html } from 'htm/preact'
import { useEffect, useRef, useCallback } from 'preact/hooks'
import { ActionButton } from '../common/button'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { SessionTraceEntry } from './session-trace-entry'
import { SessionTraceFilter } from './session-trace-filter'
import { evaluateProcessTrace, type ProcessCriticFinding, type ProcessCriticSeverity } from './process-critic'
import {
  getTraceLoading,
  getTraceError,
  getTraceEvents,
  getFilteredEvents,
  getTraceSummary,
  getTraceSearchQuery,
  loadSessionTrace,
  closeSessionTrace,
  traceSlots,
} from './session-trace-state'
import type { TraceSummary } from './session-trace-state'
import { isOfflineStatus } from '../../lib/keeper-classifiers'

// ── Summary bar ────────────────────────────────────────

function TraceSummaryBar({ summary }: { summary: TraceSummary }) {
  const s = summary
  if (
    s.tool_call_count === 0
    && s.oas_tool_count === 0
    && s.oas_turn_count === 0
    && s.oas_context_count === 0
    && s.broadcast_count === 0
    && s.task_completed_count === 0
    && s.oas_input_tokens === 0
    && s.oas_output_tokens === 0
    && s.oas_cache_creation_tokens === 0
    && s.oas_cache_read_tokens === 0
    && s.oas_cache_miss_input_tokens === 0
    && s.oas_llm_call_count === 0
    && s.oas_error_count === 0
  ) return null

  const items: string[] = []
  const cacheSeenTokens =
    s.oas_cache_read_tokens + s.oas_cache_miss_input_tokens
  const cacheHitPct =
    cacheSeenTokens > 0
      ? Math.round((s.oas_cache_read_tokens / cacheSeenTokens) * 100)
      : null
  if (s.tool_call_count > 0) items.push(`도구 ${s.tool_call_count}회`)
  if (s.oas_tool_count > 0) items.push(`OAS 도구 ${s.oas_tool_count}회`)
  if (s.oas_turn_count > 0) items.push(`OAS 턴 ${s.oas_turn_count}건`)
  if (s.oas_context_count > 0) items.push(`OAS 압축 ${s.oas_context_count}건`)
  if (s.oas_tokens_saved > 0) items.push(`절약 ${s.oas_tokens_saved}tok`)
  if (s.oas_input_tokens > 0 || s.oas_output_tokens > 0) {
    items.push(`OAS 토큰 ${s.oas_input_tokens}→${s.oas_output_tokens}`)
  }
  if (s.oas_cache_read_tokens > 0) items.push(`캐시 read ${s.oas_cache_read_tokens}tok`)
  if (s.oas_cache_creation_tokens > 0) items.push(`캐시 write ${s.oas_cache_creation_tokens}tok`)
  if (s.oas_cache_miss_input_tokens > 0) items.push(`캐시 miss ${s.oas_cache_miss_input_tokens}tok`)
  if (cacheHitPct != null) items.push(`캐시 hit ${cacheHitPct}%`)
  if (s.oas_llm_call_count > 0) items.push(`LLM 호출 ${s.oas_llm_call_count}회`)
  if (s.oas_error_count > 0) items.push(`OAS 에러 ${s.oas_error_count}건`)
  if (s.task_completed_count > 0) items.push(`완료 ${s.task_completed_count}건`)
  if (s.task_claimed_count > 0) items.push(`할당 ${s.task_claimed_count}건`)
  if (s.broadcast_count > 0) items.push(`메시지 ${s.broadcast_count}건`)
  if (s.total_cost_usd > 0) items.push(`$${s.total_cost_usd.toFixed(3)}`)

  return html`
    <div class="v2-monitoring-trace-summary flex flex-wrap gap-2 text-3xs text-[var(--color-fg-muted)]">
      ${items.map(item => html`
        <span class="inline-flex items-center bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] px-2 py-1 rounded-[var(--r-1)] font-medium">
          ${item}
        </span>
      `)}
    </div>
  `
}

function processCriticToneClass(severity: ProcessCriticSeverity): string {
  if (severity === 'action') return 'border-[var(--warn-20)] bg-[var(--warn-soft)]'
  if (severity === 'warning') return 'border-[var(--warn-border)] bg-[var(--color-bg-elevated)]'
  return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'
}

function ProcessCriticPanel({ findings }: { findings: readonly ProcessCriticFinding[] }) {
  if (findings.length === 0) return null

  return html`
    <section
      class="v2-monitoring-process-critic rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-subtle)] px-3 py-2.5"
      aria-label="Process Critic"
    >
      <div class="mb-2 flex items-center gap-2">
        <span class="inline-flex h-5 min-w-5 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] px-1 font-mono text-[10px] text-[var(--color-fg-muted)]">
          PC
        </span>
        <span class="text-2xs font-semibold text-[var(--color-fg-primary)]">Process Critic</span>
        <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-1.5 py-0.5 text-3xs uppercase text-[var(--color-fg-muted)]">
          advisory
        </span>
      </div>
      <div class="grid gap-1.5">
        ${findings.map(finding => html`
          <article
            key=${finding.id}
            class="rounded-[var(--r-1)] border px-2.5 py-2 ${processCriticToneClass(finding.severity)}"
          >
            <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
              <span class="text-2xs font-semibold text-[var(--color-fg-primary)]">${finding.title}</span>
              <span class="text-3xs uppercase text-[var(--color-fg-muted)]">${finding.severity}</span>
              <span class="ml-auto text-3xs font-medium text-[var(--color-accent-fg)]">${finding.action}</span>
            </div>
            <p class="mt-1 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${finding.detail}</p>
            <div class="mt-1.5 flex flex-wrap gap-1">
              ${finding.evidence.map((item, index) => html`
                <span
                  key=${`${finding.id}-${index}`}
                  class="max-w-full truncate rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-1.5 py-0.5 font-mono text-[10px] text-[var(--color-fg-muted)]"
                >
                  ${item}
                </span>
              `)}
            </div>
          </article>
        `)}
      </div>
    </section>
  `
}

// ── Live indicator ─────────────────────────────────────

function LiveIndicator({ events }: { events: readonly { ts: number }[] }) {
  if (events.length === 0) return null

  const lastEvt = events[0]
  if (!lastEvt) return null
  const isRecent = Date.now() - lastEvt.ts < 60_000
  if (!isRecent) return null

  return html`
    <div class="v2-monitoring-trace-live flex items-center gap-2 px-3 py-2 text-2xs text-[var(--color-fg-muted)]">
      <span class="relative flex size-2">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-[var(--r-0)] bg-[var(--color-status-ok)] opacity-75"></span>
        <span class="relative inline-flex size-2 rounded-[var(--r-0)] bg-[var(--color-status-ok)]"></span>
      </span>
      에이전트 작업 중...
    </div>
  `
}

// ── Main view ──────────────────────────────────────────

interface SessionTraceViewProps {
  agentName: string
  isKeeper: boolean
  keeperStatus?: string
  keeperGeneration?: number
}

export function SessionTraceView({ agentName, isKeeper, keeperStatus, keeperGeneration }: SessionTraceViewProps) {
  const listRef = useRef<HTMLDivElement>(null)

  // Load on first mount. Clean up only when agentName changes (overlay closes).
  // CollapsibleSection uses native <details> — children stay mounted when collapsed.
  useEffect(() => {
    void loadSessionTrace(agentName, isKeeper)
    return () => {
      closeSessionTrace(agentName)
    }
  }, [agentName, isKeeper])

  // Subscribe to traceSlots changes for reactivity.
  void traceSlots.value

  const loading = getTraceLoading(agentName)
  const error = getTraceError(agentName)
  const processEvents = getTraceEvents(agentName)
  const events = getFilteredEvents(agentName)
  const summary = getTraceSummary(agentName)
  const searchQuery = getTraceSearchQuery(agentName)
  const processFindings = evaluateProcessTrace({ events: processEvents, summary })

  // Auto-scroll to top when new events arrive (newest-first order)
  const prevCountRef = useRef(0)
  useEffect(() => {
    if (events.length > prevCountRef.current && listRef.current) {
      const el = listRef.current
      const isNearTop = el.scrollTop < 100
      if (isNearTop) {
        el.scrollTop = 0
      }
    }
    prevCountRef.current = events.length
  }, [events.length])

  const handleRefresh = useCallback(() => {
    void loadSessionTrace(agentName, isKeeper)
  }, [agentName, isKeeper])

  // Loading state
  if (loading && events.length === 0) {
    return html`<${LoadingState}>활동 추적 불러오는 중...<//>`
  }

  // Error state
  if (error) {
    return html`
      <div class="v2-monitoring-trace-error flex flex-col items-center gap-3 py-4">
        <${ErrorState} message=${error} />
        <${ActionButton} variant="ghost" size="sm" onClick=${handleRefresh}>재시도<//>
      </div>
    `
  }

  // Empty state — contextual message based on keeper status
  if (events.length === 0) {
    const isOffline = keeperStatus && isOfflineStatus(keeperStatus)
    const msg = isOffline
      ? '키퍼가 오프라인입니다. 기동하면 활동이 기록됩니다.'
      : (keeperGeneration ?? 0) === 0
        ? '아직 시작되지 않은 키퍼입니다. 활동 기록이 없습니다.'
        : '현재 세대에서 기록된 활동이 없습니다.'
    return html`
      <div class="py-4">
        <${EmptyState} message=${msg} compact />
      </div>
    `
  }

  return html`
    <div class="v2-monitoring-trace-surface flex flex-col gap-3">
      ${'' /* Filter + Refresh */}
      <div class="flex items-center justify-between gap-3">
        <${SessionTraceFilter} agentName=${agentName} />
        <${ActionButton}
          variant="ghost"
          size="sm"
          onClick=${handleRefresh}
          disabled=${loading}
        >
          ${loading ? '로딩...' : '새로고침'}
        <//>
      </div>

      ${'' /* Summary */}
      <${TraceSummaryBar} summary=${summary} />
      <${ProcessCriticPanel} findings=${processFindings} />

      ${'' /* Event list */}
      <div
        ref=${listRef}
        class="v2-monitoring-trace-list flex flex-col gap-0.5 max-h-[500px] overflow-y-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      >
        ${events.map(evt => html`<${SessionTraceEntry} key=${evt.id} event=${evt} searchQuery=${searchQuery} />`)}
        <${LiveIndicator} events=${events} />
      </div>

      ${'' /* Footer: event count */}
      <div class="v2-monitoring-trace-footer text-3xs text-[var(--color-fg-disabled)] text-right">
        ${events.length}건 표시
      </div>
    </div>
  `
}
