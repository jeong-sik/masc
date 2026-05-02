// FailureHistory — AX organism for agent failure pattern dashboard.
//
// Kimi design system sec05 reference: failure & recovery patterns.
// Displays failure frequency, error types, and correlation summary.

import { html } from 'htm/preact'

export interface FailureEntry {
  id: string
  agentId: string
  errorType: string
  message: string
  timestamp: number
  retryable: boolean
  resolved?: boolean
}

interface FailureHistoryProps {
  failures: FailureEntry[]
  onRetry?: (id: string) => void
  onDismiss?: (id: string) => void
  testId?: string
}

const ERROR_ICON: Record<string, string> = {
  network: '\u{1F50C}',
  timeout: '\u{23F1}',
  auth: '\u{1F510}',
  quota: '\u{1F4B8}',
  crash: '\u{1F4A5}',
  default: '\u{26A0}',
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  return d.toLocaleString('ko-KR', {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function FailureHistory({
  failures,
  onRetry,
  onDismiss,
  testId,
}: FailureHistoryProps) {
  const total = failures.length
  const resolvedCount = failures.filter((f) => f.resolved).length
  const retryableCount = failures.filter((f) => f.retryable && !f.resolved).length

  const typeCounts = failures.reduce<Record<string, number>>((acc, f) => {
    acc[f.errorType] = (acc[f.errorType] || 0) + 1
    return acc
  }, {})

  const topTypes = Object.entries(typeCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      role="region"
      aria-label="실패 이력"
      data-failure-history
      data-testid=${testId}
    >
      <div class="mb-3 flex items-center justify-between">
        <h4 class="text-sm font-medium text-[var(--color-fg-primary)]">실패 이력</h4>
        <span class="text-xs text-[var(--color-fg-secondary)]">
          ${resolvedCount}/${total} 해결
        </span>
      </div>

      ${topTypes.length > 0
        ? html`
            <div class="mb-3 flex flex-wrap gap-2">
              ${topTypes.map(
                ([type, count]) => html`
                  <span
                    key=${type}
                    class="inline-flex items-center rounded-[var(--r-1)] bg-[var(--white-5)] px-2 py-0.5 text-xs text-[var(--color-fg-secondary)]"
                  >
                    ${ERROR_ICON[type] || ERROR_ICON.default}
                    <span class="ml-1">${type}</span>
                    <span class="ml-1 text-[var(--color-fg-primary)]">${count}</span>
                  </span>
                `,
              )}
            </div>
          `
        : null}

      <div role="list" class="space-y-2">
        ${failures.map((f) => {
          const icon = ERROR_ICON[f.errorType] || ERROR_ICON.default
          const statusClass = f.resolved
            ? 'text-[var(--color-fg-secondary)] line-through opacity-60'
            : 'text-[var(--color-fg-primary)]'
          return html`
            <div
              key=${f.id}
              role="listitem"
              class="flex items-start gap-2 rounded-[var(--r-1)] border border-[var(--white-5)] p-2"
              data-failure-id=${f.id}
            >
              <span class="mt-0.5 text-xs" aria-hidden="true">${icon}</span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1">
                  <span class="text-xs font-mono text-[var(--color-fg-secondary)]">
                    ${f.agentId.slice(0, 8)}
                  </span>
                  <span class="text-xs text-[var(--color-fg-secondary)]">·</span>
                  <span class="text-xs text-[var(--color-fg-secondary)]">${formatTime(f.timestamp)}</span>
                </div>
                <div class="mt-0.5 text-sm ${statusClass}">${f.message}</div>
              </div>
              <div class="flex items-center gap-1">
                ${f.retryable && !f.resolved && onRetry
                  ? html`
                      <button
                        class="rounded px-2 py-1 text-xs text-[var(--color-accent)] hover:bg-[var(--white-5)]"
                        onClick=${() => onRetry(f.id)}
                        aria-label="${f.message} 재시도"
                      >
                        재시도
                      </button>
                    `
                  : null}
                ${onDismiss && !f.resolved
                  ? html`
                      <button
                        class="rounded px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--white-5)]"
                        onClick=${() => onDismiss(f.id)}
                        aria-label="${f.message} 해제"
                      >
                        해제
                      </button>
                    `
                  : null}
              </div>
            </div>
          `
        })}
      </div>

      ${retryableCount > 0 && onRetry
        ? html`
            <button
              class="mt-3 w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] py-1.5 text-sm text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--white-5)]"
              onClick=${() => failures.filter((f) => f.retryable && !f.resolved).forEach((f) => onRetry?.(f.id))}
            >
              미해결 ${retryableCount}건 일괄 재시도
            </button>
          `
        : null}
    </div>
  `
}
