// EventStream — AX molecule for real-time event log visualization.
//
// Kimi design system sec02 reference: 2.1.3 agent log stream with level-based
// color coding and live append semantics.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

export interface StreamEvent {
  id: string
  timestamp: number
  level: 'info' | 'warn' | 'error'
  message: string
  source?: string
}

export type EventStreamStatus = 'empty' | 'ok' | 'warning' | 'error'

export interface EventStreamSummary {
  totalCount: number
  visibleCount: number
  hiddenCount: number
  infoCount: number
  warnCount: number
  errorCount: number
  latestTimestamp: number | null
  oldestVisibleTimestamp: number | null
  status: EventStreamStatus
}

interface EventStreamProps {
  events: StreamEvent[]
  maxItems?: number
  testId?: string
}

function levelColor(level: string): string {
  return level === 'error'
    ? 'var(--color-status-err)'
    : level === 'warn'
      ? 'var(--color-status-warn)'
      : 'var(--color-status-info)'
}

function levelLabel(level: string): string {
  return level === 'error' ? '에러' : level === 'warn' ? '경고' : '정보'
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return '--:--:--'
  return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}:${d.getSeconds().toString().padStart(2, '0')}`
}

function formatDateTime(ts: number): string | undefined {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return undefined
  return d.toISOString()
}

export function getVisibleStreamEvents(events: StreamEvent[], maxItems: number): StreamEvent[] {
  const itemLimit = Number.isFinite(maxItems) ? Math.max(0, Math.floor(maxItems)) : 0
  if (itemLimit === 0) return []
  return events.slice(-itemLimit).reverse()
}

export function summarizeEventStream(events: StreamEvent[], maxItems: number): EventStreamSummary {
  const visible = getVisibleStreamEvents(events, maxItems)
  const infoCount = visible.filter(e => e.level === 'info').length
  const warnCount = visible.filter(e => e.level === 'warn').length
  const errorCount = visible.filter(e => e.level === 'error').length
  const status: EventStreamStatus =
    visible.length === 0
      ? 'empty'
      : errorCount > 0
        ? 'error'
        : warnCount > 0
          ? 'warning'
          : 'ok'

  return {
    totalCount: events.length,
    visibleCount: visible.length,
    hiddenCount: Math.max(0, events.length - visible.length),
    infoCount,
    warnCount,
    errorCount,
    latestTimestamp: visible[0]?.timestamp ?? null,
    oldestVisibleTimestamp: visible[visible.length - 1]?.timestamp ?? null,
    status,
  }
}

export function EventStream({ events, maxItems = 100, testId }: EventStreamProps) {
  const visible = useMemo(() => getVisibleStreamEvents(events, maxItems), [events, maxItems])
  const summary = useMemo(() => summarizeEventStream(events, maxItems), [events, maxItems])

  return html`
    <div
      class="h-64 space-y-2 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2"
      data-event-stream
      data-event-stream-total-count=${summary.totalCount}
      data-event-stream-visible-count=${summary.visibleCount}
      data-event-stream-hidden-count=${summary.hiddenCount}
      data-event-stream-info-count=${summary.infoCount}
      data-event-stream-warn-count=${summary.warnCount}
      data-event-stream-error-count=${summary.errorCount}
      data-event-stream-status=${summary.status}
      data-event-stream-latest-timestamp=${summary.latestTimestamp ?? ''}
      data-event-stream-oldest-visible-timestamp=${summary.oldestVisibleTimestamp ?? ''}
      data-testid=${testId}
    >
      <div
        class="grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
        aria-label="이벤트 스트림 요약"
      >
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">전체</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.totalCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">표시</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">
            ${summary.visibleCount}/${summary.totalCount}
          </div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">에러</div>
          <div class="font-mono text-sm text-[var(--color-status-err)]">${summary.errorCount}</div>
        </div>
      </div>
      <div
        role="log"
        aria-label="이벤트 스트림, 이벤트 ${summary.visibleCount}개, 에러 ${summary.errorCount}개"
        aria-live="polite"
        aria-atomic="false"
      >
        ${visible.length === 0
          ? html`<div class="text-3xs text-[var(--color-fg-muted)]">이벤트 없음</div>`
          : html`
            <div class="space-y-1" role="list">
              ${visible.map(
                (e, index) => html`
                  <div
                    key=${e.id}
                    class="flex min-w-0 items-start gap-2 rounded-[var(--r-1)] px-2 py-1 hover:bg-[var(--color-bg-hover)]"
                    role="listitem"
                    data-stream-event-id=${e.id}
                    data-stream-event-level=${e.level}
                    data-stream-event-source=${e.source ?? ''}
                    data-stream-event-timestamp=${e.timestamp}
                    data-stream-event-visible-index=${index}
                  >
                    <span
                      class="mt-0.5 inline-block h-1.5 w-1.5 flex-shrink-0 rounded-full"
                      style=${{ background: levelColor(e.level) }}
                      aria-hidden="true"
                    ></span>
                    <time
                      class="shrink-0 font-mono text-3xs text-[var(--color-fg-secondary)] tabular-nums"
                      datetime=${formatDateTime(e.timestamp)}
                      >${formatTime(e.timestamp)}</time
                    >
                    ${e.source
                      ? html`<span
                          class="max-w-24 shrink-0 truncate text-3xs text-[var(--color-fg-muted)]"
                          title=${e.source}
                          >[${e.source}]</span
                        >`
                      : null}
                    <span class="min-w-0 flex-1 break-words text-xs text-[var(--color-fg-primary)]"
                      >${e.message}</span
                    >
                    <span class="sr-only">${levelLabel(e.level)}</span>
                  </div>
                `,
              )}
            </div>
          `}
      </div>
    </div>
  `
}
