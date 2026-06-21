// Dedicated Schedule surface.
//
// The card/detail projection lives in tools/scheduled-automation-panel.ts and
// is reused here so the route does not fork the backed schedule semantics.

import { html } from 'htm/preact'
import { RefreshCw } from 'lucide-preact'
import { useEffect } from 'preact/hooks'
import type { DashboardScheduledAutomation, DashboardScheduledAutomationRequest } from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { ScheduledAutomationPanel } from '../tools/scheduled-automation-panel'
import {
  loadTools,
  toolsData,
  toolsError,
  toolsLoading,
} from '../tools/tool-state'

function countLabel(count: number): string {
  return count.toLocaleString()
}

function normalizedStatus(request: DashboardScheduledAutomationRequest): string {
  return (request.effective_status ?? request.status ?? '').trim().toLowerCase()
}

function countByStatus(
  automation: DashboardScheduledAutomation | null,
  statuses: readonly string[],
): number {
  if (!automation) return 0
  const normalizedStatuses = statuses.map(status => status.toLowerCase())
  const hasCountKey = normalizedStatuses.some(status =>
    Object.prototype.hasOwnProperty.call(automation.counts ?? {}, status),
  )
  if (hasCountKey) {
    return normalizedStatuses.reduce((sum, status) => sum + (automation.counts?.[status] ?? 0), 0)
  }
  return (automation.requests ?? [])
    .filter(request => normalizedStatuses.includes(normalizedStatus(request)))
    .length
}

export function ScheduleSurface() {
  const data = toolsData.value
  const automation = data?.scheduled_automation ?? null
  const loading = toolsLoading.value
  const error = toolsError.value
  const dueEffective = automation?.derived_counts?.due_effective ?? 0
  const pendingCount = countByStatus(automation, ['pending', 'pending_approval', 'awaiting_approval'])
  const scheduledCount = countByStatus(automation, ['scheduled'])
  const runningCount = countByStatus(automation, ['running'])
  const generatedAt = automation?.generated_at ?? data?.generated_at ?? null
  const signalCount = automation?.signal_count ?? automation?.signals?.length ?? 0

  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }
  }, [])

  return html`
    <main class="ov ss-surface bg-surface-page text-text-primary" data-testid="schedule-surface">
      <div class="ov-scroll">
        <header class="ov-head">
          <div>
            <h1>예약 자동화</h1>
            <p class="ov-sub">
              keeper 예약 요청 · 승인 차단 · 실행 준비 · durable wake signal
            </p>
          </div>
          <button
            type="button"
            class="v2-shell-action inline-flex min-h-10 items-center gap-2 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2 text-xs text-[var(--color-fg-secondary)] transition-colors hover:border-[var(--color-accent-fg)] hover:text-[var(--color-fg-primary)] disabled:cursor-not-allowed disabled:opacity-60"
            onClick=${() => { void loadTools() }}
            disabled=${loading}
            aria-busy=${loading ? 'true' : 'false'}
            data-testid="schedule-refresh"
          >
            <${RefreshCw} size=${14} aria-hidden="true" />
            <span>${loading ? '새로고침 중' : '새로고침'}</span>
          </button>
        </header>

        ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}

        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }} aria-label="Schedule summary">
          <div class="ov-kpi">
            <div class="ov-kpi-k">pending</div>
            <div class=${`ov-kpi-v ${pendingCount > 0 ? 'warn' : 'ok'}`}>${countLabel(pendingCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">due</div>
            <div class=${`ov-kpi-v ${dueEffective > 0 ? 'warn' : 'ok'}`}>${countLabel(dueEffective)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">scheduled</div>
            <div class=${`ov-kpi-v ${scheduledCount > 0 ? 'volt' : ''}`}>${countLabel(scheduledCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">running</div>
            <div class=${`ov-kpi-v ${runningCount > 0 ? 'ok' : ''}`}>${countLabel(runningCount)}</div>
          </div>
        </section>

        <div class="mb-3 flex flex-wrap gap-x-4 gap-y-1 text-3xs text-[var(--color-fg-muted)]">
          <span>
            출처 <span class="font-mono text-[var(--color-fg-secondary)]">${automation?.source ?? 'schedule_store'}</span>
          </span>
          <span>
            signal 행 <span class="font-mono text-[var(--color-fg-secondary)]">${countLabel(signalCount)}</span>
          </span>
          <span>
            생성 <span class="font-mono text-[var(--color-fg-secondary)]">${formatDateTimeKo(generatedAt)}</span>
          </span>
        </div>

        ${loading && !automation
          ? html`<${LoadingState}>예약 자동화 projection 불러오는 중...<//>`
          : html`<${ScheduledAutomationPanel} automation=${automation} />`}
      </div>
    </main>
  `
}
