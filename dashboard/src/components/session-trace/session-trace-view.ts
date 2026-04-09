// Session trace view — main container for GitHub Agents-style activity trace.
// Each instance reads state by its own agentName prop, avoiding global state corruption
// when multiple overlays are open simultaneously.

import { html } from 'htm/preact'
import { useEffect, useRef, useCallback } from 'preact/hooks'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/empty-state'
import { SessionTraceEntry } from './session-trace-entry'
import { SessionTraceFilter } from './session-trace-filter'
import {
  getTraceLoading,
  getTraceError,
  getFilteredEvents,
  getTraceSummary,
  loadSessionTrace,
  closeSessionTrace,
  _traceSlots,
} from './session-trace-state'
import type { TraceSummary } from './session-trace-state'

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
  ) return null

  const items: string[] = []
  if (s.tool_call_count > 0) items.push(`도구 ${s.tool_call_count}회`)
  if (s.oas_tool_count > 0) items.push(`OAS 도구 ${s.oas_tool_count}회`)
  if (s.oas_turn_count > 0) items.push(`OAS 턴 ${s.oas_turn_count}건`)
  if (s.oas_context_count > 0) items.push(`OAS 압축 ${s.oas_context_count}건`)
  if (s.task_completed_count > 0) items.push(`완료 ${s.task_completed_count}건`)
  if (s.task_claimed_count > 0) items.push(`할당 ${s.task_claimed_count}건`)
  if (s.broadcast_count > 0) items.push(`메시지 ${s.broadcast_count}건`)
  if (s.total_cost_usd > 0) items.push(`$${s.total_cost_usd.toFixed(3)}`)

  return html`
    <div class="flex flex-wrap gap-2 text-[10px] text-[var(--text-muted)]">
      ${items.map(item => html`
        <span class="inline-flex items-center bg-[var(--white-4)] border border-[var(--white-6)] px-2 py-1 rounded-md font-medium">
          ${item}
        </span>
      `)}
    </div>
  `
}

// ── Live indicator ─────────────────────────────────────

function LiveIndicator({ events }: { events: readonly { ts: number }[] }) {
  if (events.length === 0) return null

  const lastEvt = events[events.length - 1]
  if (!lastEvt) return null
  const isRecent = Date.now() - lastEvt.ts < 60_000
  if (!isRecent) return null

  return html`
    <div class="flex items-center gap-2 px-3 py-2 text-[11px] text-[var(--text-muted)]">
      <span class="relative flex size-2">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-[var(--ok)] opacity-75"></span>
        <span class="relative inline-flex size-2 rounded-full bg-[var(--ok)]"></span>
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

  // Subscribe to traceSlots changes for reactivity
  void _traceSlots.value

  const loading = getTraceLoading(agentName)
  const error = getTraceError(agentName)
  const events = getFilteredEvents(agentName)
  const summary = getTraceSummary(agentName)

  // Auto-scroll to bottom when new events arrive
  const prevCountRef = useRef(0)
  useEffect(() => {
    if (events.length > prevCountRef.current && listRef.current) {
      const el = listRef.current
      const isNearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 100
      if (isNearBottom) {
        el.scrollTop = el.scrollHeight
      }
    }
    prevCountRef.current = events.length
  }, [events.length])

  const handleRefresh = useCallback(() => {
    void loadSessionTrace(agentName, isKeeper)
  }, [agentName, isKeeper])

  // Loading state
  if (loading && events.length === 0) {
    return html`<div class="py-8 text-center text-[var(--text-muted)] text-xs">활동 추적 로딩 중...</div>`
  }

  // Error state
  if (error) {
    return html`
      <div class="py-4">
        <div class="text-xs text-[var(--bad)] mb-2">${error}</div>
        <${ActionButton} variant="ghost" size="sm" onClick=${handleRefresh}>재시도<//>
      </div>
    `
  }

  // Empty state — contextual message based on keeper status
  if (events.length === 0) {
    const isOffline = keeperStatus && ['offline', 'inactive', 'dead', 'crashed'].includes(keeperStatus)
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
    <div class="flex flex-col gap-3">
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

      ${'' /* Event list */}
      <div
        ref=${listRef}
        class="flex flex-col gap-0.5 max-h-[500px] overflow-y-auto rounded-lg border border-[var(--card-border)] bg-[var(--white-2)]"
      >
        ${events.map(evt => html`<${SessionTraceEntry} key=${evt.id} event=${evt} />`)}
        <${LiveIndicator} events=${events} />
      </div>

      ${'' /* Footer: event count */}
      <div class="text-[10px] text-[var(--text-dim)] text-right">
        ${events.length}건 표시
      </div>
    </div>
  `
}
