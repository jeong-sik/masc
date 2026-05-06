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

export type FailureEntryStatus = 'resolved' | 'retryable' | 'blocked'
export type FailureHistoryStatus = 'empty' | 'resolved' | 'actionable' | 'blocked'

export interface FailureTypeSummary {
  readonly errorType: string
  readonly count: number
  readonly resolvedCount: number
  readonly retryableCount: number
  readonly latestTimestamp: number | null
}

export interface FailureHistorySummary {
  readonly totalCount: number
  readonly resolvedCount: number
  readonly unresolvedCount: number
  readonly retryableCount: number
  readonly blockedCount: number
  readonly typeCount: number
  readonly latestTimestamp: number | null
  readonly topTypes: FailureTypeSummary[]
  readonly status: FailureHistoryStatus
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
  if (!Number.isFinite(ts)) return '--'
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return '--'
  return d.toLocaleString('ko-KR', {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function formatDateTime(ts: number): string | undefined {
  if (!Number.isFinite(ts)) return undefined
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return undefined
  return d.toISOString()
}

export function failureEntryStatus(failure: FailureEntry): FailureEntryStatus {
  if (failure.resolved) return 'resolved'
  return failure.retryable ? 'retryable' : 'blocked'
}

export function summarizeFailureHistory(failures: FailureEntry[], topTypeLimit = 3): FailureHistorySummary {
  const typeSummaries = new Map<string, { count: number; resolvedCount: number; retryableCount: number; latestTimestamp: number | null }>()
  let resolvedCount = 0
  let retryableCount = 0
  let latestTimestamp: number | null = null

  failures.forEach((failure) => {
    if (failure.resolved) {
      resolvedCount += 1
    } else if (failure.retryable) {
      retryableCount += 1
    }

    if (Number.isFinite(failure.timestamp)) {
      latestTimestamp = latestTimestamp === null ? failure.timestamp : Math.max(latestTimestamp, failure.timestamp)
    }

    const type = typeSummaries.get(failure.errorType) ?? {
      count: 0,
      resolvedCount: 0,
      retryableCount: 0,
      latestTimestamp: null,
    }
    type.count += 1
    if (failure.resolved) type.resolvedCount += 1
    if (failure.retryable && !failure.resolved) type.retryableCount += 1
    if (Number.isFinite(failure.timestamp)) {
      type.latestTimestamp = type.latestTimestamp === null ? failure.timestamp : Math.max(type.latestTimestamp, failure.timestamp)
    }
    typeSummaries.set(failure.errorType, type)
  })

  const totalCount = failures.length
  const unresolvedCount = totalCount - resolvedCount
  const blockedCount = unresolvedCount - retryableCount
  const limit = Number.isFinite(topTypeLimit) ? Math.max(0, Math.floor(topTypeLimit)) : 0
  const topTypes = Array.from(typeSummaries.entries())
    .map(([errorType, summary]) => ({ errorType, ...summary }))
    .sort((a, b) => b.count - a.count || (b.latestTimestamp ?? 0) - (a.latestTimestamp ?? 0) || a.errorType.localeCompare(b.errorType))
    .slice(0, limit)
  const status: FailureHistoryStatus =
    totalCount === 0
      ? 'empty'
      : unresolvedCount === 0
        ? 'resolved'
        : retryableCount > 0
          ? 'actionable'
          : 'blocked'

  return {
    totalCount,
    resolvedCount,
    unresolvedCount,
    retryableCount,
    blockedCount,
    typeCount: typeSummaries.size,
    latestTimestamp,
    topTypes,
    status,
  }
}

export function FailureHistory({
  failures,
  onRetry,
  onDismiss,
  testId,
}: FailureHistoryProps) {
  const summary = summarizeFailureHistory(failures)
  const topType = summary.topTypes[0]

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      role="region"
      aria-label="실패 이력"
      data-failure-history
      data-failure-history-total-count=${summary.totalCount}
      data-failure-history-resolved-count=${summary.resolvedCount}
      data-failure-history-unresolved-count=${summary.unresolvedCount}
      data-failure-history-retryable-count=${summary.retryableCount}
      data-failure-history-blocked-count=${summary.blockedCount}
      data-failure-history-type-count=${summary.typeCount}
      data-failure-history-latest-timestamp=${summary.latestTimestamp ?? ''}
      data-failure-history-top-error-type=${topType?.errorType ?? ''}
      data-failure-history-top-error-count=${topType?.count ?? 0}
      data-failure-history-status=${summary.status}
      data-testid=${testId}
    >
      <div class="mb-3 flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
        <h4 class="text-sm font-medium text-[var(--color-fg-primary)]">실패 이력</h4>
        <span class="text-xs text-[var(--color-fg-secondary)]">
          ${summary.resolvedCount}/${summary.totalCount} 해결
        </span>
      </div>

      <div
        class="mb-3 grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
        aria-label="실패 이력 요약"
        data-failure-history-summary
      >
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">전체</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.totalCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">미해결</div>
          <div class="font-mono text-sm text-[var(--color-status-err)]">${summary.unresolvedCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">재시도</div>
          <div class="font-mono text-sm text-[var(--color-status-warn)]">${summary.retryableCount}</div>
        </div>
      </div>

      ${summary.topTypes.length > 0
        ? html`
            <div class="mb-3 flex flex-wrap gap-2" aria-label="상위 실패 유형" data-failure-history-top-types>
              ${summary.topTypes.map(
                (type) => html`
                  <span
                    key=${type.errorType}
                    class="inline-flex items-center rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-xs text-[var(--color-fg-secondary)]"
                    data-failure-history-type=${type.errorType}
                    data-failure-history-type-count=${type.count}
                    data-failure-history-type-resolved-count=${type.resolvedCount}
                    data-failure-history-type-retryable-count=${type.retryableCount}
                    data-failure-history-type-latest-timestamp=${type.latestTimestamp ?? ''}
                  >
                    ${ERROR_ICON[type.errorType] || ERROR_ICON.default}
                    <span class="ml-1">${type.errorType}</span>
                    <span class="ml-1 text-[var(--color-fg-primary)]">${type.count}</span>
                  </span>
                `,
              )}
            </div>
          `
        : null}

      <div role="list" class="space-y-2" aria-label="실패 목록, 총 ${summary.totalCount}건">
        ${failures.length === 0
          ? html`
              <div
                role="listitem"
                class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-divider)] p-2 text-xs text-[var(--color-fg-muted)]"
                data-failure-history-empty
              >
                기록된 실패 없음
              </div>
            `
          : failures.map((f) => {
          const icon = ERROR_ICON[f.errorType] || ERROR_ICON.default
          const status = failureEntryStatus(f)
          const statusClass = f.resolved
            ? 'text-[var(--color-fg-secondary)] line-through opacity-60'
            : 'text-[var(--color-fg-primary)]'
          const canRetry = f.retryable && !f.resolved && onRetry
          const canDismiss = onDismiss && !f.resolved
          return html`
            <div
              key=${f.id}
              role="listitem"
              class="grid grid-cols-[auto_minmax(0,1fr)] gap-2 rounded-[var(--r-1)] border border-[var(--color-border-divider)] p-2 sm:grid-cols-[auto_minmax(0,1fr)_auto]"
              data-failure-id=${f.id}
              data-failure-agent-id=${f.agentId}
              data-failure-error-type=${f.errorType}
              data-failure-timestamp=${f.timestamp}
              data-failure-retryable=${f.retryable}
              data-failure-resolved=${Boolean(f.resolved)}
              data-failure-status=${status}
            >
              <span class="mt-0.5 text-xs" aria-hidden="true">${icon}</span>
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-x-1 gap-y-0.5">
                  <span class="text-xs font-mono text-[var(--color-fg-secondary)]">
                    ${f.agentId.slice(0, 8)}
                  </span>
                  <span class="text-xs text-[var(--color-fg-secondary)]">·</span>
                  <time class="text-xs text-[var(--color-fg-secondary)]" datetime=${formatDateTime(f.timestamp)}>
                    ${formatTime(f.timestamp)}
                  </time>
                </div>
                <div class="mt-0.5 break-words text-sm ${statusClass}">${f.message}</div>
              </div>
              ${canRetry || canDismiss
                ? html`
                    <div class="col-start-2 flex flex-wrap items-center gap-1 sm:col-start-auto sm:justify-end">
                      ${canRetry
                  ? html`
                      <button
                        class="rounded-[var(--r-1)] px-2 py-1 text-xs text-[var(--color-accent-fg)] hover:bg-[var(--color-bg-elevated)]"
                        onClick=${() => onRetry?.(f.id)}
                        aria-label="${f.message} 재시도"
                      >
                        재시도
                      </button>
                  `
                  : null}
                ${canDismiss
                  ? html`
                      <button
                        class="rounded-[var(--r-1)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-elevated)]"
                        onClick=${() => onDismiss?.(f.id)}
                        aria-label="${f.message} 해제"
                      >
                        해제
                      </button>
                    `
                  : null}
                    </div>
                  `
                : null}
            </div>
          `
        })}
      </div>

      ${summary.retryableCount > 0 && onRetry
        ? html`
            <button
              class="mt-3 w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] py-1.5 text-sm text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-elevated)]"
              onClick=${() => failures.filter((f) => f.retryable && !f.resolved).forEach((f) => onRetry?.(f.id))}
            >
              미해결 ${summary.retryableCount}건 일괄 재시도
            </button>
          `
        : null}
    </div>
  `
}
