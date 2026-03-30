// Session trace view — main container for GitHub Agents-style activity trace.
// Lazy-loaded inside a CollapsibleSection: fetches data only when opened.
// State is cleaned up only when the parent overlay closes (agentName changes).

import { html } from 'htm/preact'
import { useEffect, useRef, useCallback } from 'preact/hooks'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/empty-state'
import { SessionTraceEntry } from './session-trace-entry'
import { SessionTraceFilter } from './session-trace-filter'
import {
  traceLoading,
  traceError,
  filteredEvents,
  traceSummary,
  loadSessionTrace,
  closeSessionTrace,
  activeTraceAgent,
} from './session-trace-state'

// ── Summary bar ────────────────────────────────────────

function TraceSummaryBar() {
  const s = traceSummary.value
  if (s.tool_call_count === 0 && s.broadcast_count === 0 && s.task_completed_count === 0) return null

  const items: string[] = []
  if (s.tool_call_count > 0) items.push(`도구 ${s.tool_call_count}회`)
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

function LiveIndicator() {
  const events = filteredEvents.value
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
}

export function SessionTraceView({ agentName, isKeeper }: SessionTraceViewProps) {
  const listRef = useRef<HTMLDivElement>(null)

  // Load on first mount. Clean up only when agentName changes (overlay closes).
  // Collapsing/expanding the CollapsibleSection does NOT destroy state.
  useEffect(() => {
    activeTraceAgent.value = agentName
    void loadSessionTrace(agentName, isKeeper)
    return () => {
      closeSessionTrace(agentName)
    }
  }, [agentName, isKeeper])

  // Auto-scroll to bottom when new events arrive
  const prevCountRef = useRef(0)
  const events = filteredEvents.value

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
  if (traceLoading.value && events.length === 0) {
    return html`<div class="py-8 text-center text-[var(--text-muted)] text-xs">활동 추적 로딩 중...</div>`
  }

  // Error state
  if (traceError.value) {
    return html`
      <div class="py-4">
        <div class="text-xs text-[var(--bad)] mb-2">${traceError.value}</div>
        <${ActionButton} variant="ghost" size="sm" onClick=${handleRefresh}>재시도<//>
      </div>
    `
  }

  // Empty state
  if (events.length === 0) {
    return html`
      <div class="py-4">
        <${EmptyState} message="기록된 활동이 없습니다" compact />
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-3">
      ${'' /* Filter + Refresh */}
      <div class="flex items-center justify-between gap-3">
        <${SessionTraceFilter} />
        <${ActionButton}
          variant="ghost"
          size="sm"
          onClick=${handleRefresh}
          disabled=${traceLoading.value}
        >
          ${traceLoading.value ? '로딩...' : '새로고침'}
        <//>
      </div>

      ${'' /* Summary */}
      <${TraceSummaryBar} />

      ${'' /* Event list */}
      <div
        ref=${listRef}
        class="flex flex-col gap-0.5 max-h-[500px] overflow-y-auto rounded-lg border border-[var(--card-border)] bg-[var(--white-2)]"
      >
        ${events.map(evt => html`<${SessionTraceEntry} key=${evt.id} event=${evt} />`)}
        <${LiveIndicator} />
      </div>

      ${'' /* Footer: event count */}
      <div class="text-[10px] text-[var(--text-dim)] text-right">
        ${events.length}건 표시
      </div>
    </div>
  `
}
