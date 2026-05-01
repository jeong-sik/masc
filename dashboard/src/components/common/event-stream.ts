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

interface EventStreamProps {
  events: StreamEvent[]
  maxItems?: number
  testId?: string
}

function levelColor(level: string): string {
  return level === 'error'
    ? 'var(--error-10)'
    : level === 'warn'
      ? 'var(--warn-10)'
      : 'var(--ok-10)'
}

function levelLabel(level: string): string {
  return level === 'error' ? '에러' : level === 'warn' ? '경고' : '정보'
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}:${d.getSeconds().toString().padStart(2, '0')}`
}

export function EventStream({ events, maxItems = 100, testId }: EventStreamProps) {
  const visible = useMemo(
    () => events.slice(-maxItems).reverse(),
    [events, maxItems],
  )

  return html`
    <div
      class="h-64 overflow-auto rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2"
      data-event-stream
      data-testid=${testId}
      role="log"
      aria-label="이벤트 스트림"
      aria-live="polite"
      aria-atomic="false"
    >
      ${visible.length === 0
        ? html`<div class="text-3xs text-[var(--color-fg-muted)]">이벤트 없음</div>`
        : html`
            <div class="space-y-1" role="list">
              ${visible.map(
                e => html`
                  <div
                    key=${e.id}
                    class="flex items-start gap-2 rounded px-2 py-1 hover:bg-[var(--white-6)]"
                    role="listitem"
                  >
                    <span
                      class="mt-0.5 inline-block h-1.5 w-1.5 flex-shrink-0 rounded-full"
                      style=${{ background: levelColor(e.level) }}
                      aria-hidden="true"
                    ></span>
                    <span class="font-mono text-3xs text-[var(--color-fg-secondary)] tabular-nums"
                      >${formatTime(e.timestamp)}</span
                    >
                    ${e.source
                      ? html`<span class="text-3xs text-[var(--color-fg-muted)]">[${e.source}]</span>`
                      : null}
                    <span class="flex-1 text-xs text-[var(--color-fg-primary)]">${e.message}</span>
                    <span class="sr-only">${levelLabel(e.level)}</span>
                  </div>
                `,
              )}
            </div>
          `}
    </div>
  `
}
