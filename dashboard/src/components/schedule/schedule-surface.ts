// Dedicated Schedule surface.
//
// The card/detail projection lives in tools/scheduled-automation-panel.ts and
// is reused here so the route does not fork the backed schedule semantics.
// Shell (header + KPI strip) ported to the keeper-v2 prototype (schedule.jsx):
// `.ov.sch-surf` → `.ov-head` (eyebrow + title + sub) → `.ov-kpis` (4 KPIs).

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { ConnectionStatus } from '../dashboard-shell'
import type { DashboardScheduledAutomation } from '../../api'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { StatusChip } from '../common/status-chip'
import { ScheduleAside, ScheduledAutomationPanel, normalizedScheduleStatus, scheduledPendingApprovalCount } from '../tools/scheduled-automation-panel'
import {
  loadTools,
  toolsData,
  toolsError,
  toolsLoading,
} from '../tools/tool-state'

function countLabel(count: number): string {
  return count.toLocaleString()
}

function countByStatus(
  automation: DashboardScheduledAutomation | null,
  statuses: readonly string[],
): number {
  if (!automation) return 0
  const normalizedStatuses = statuses.map(normalizedScheduleStatus)
  const fromCounts = normalizedStatuses.reduce((sum, status) => sum + (automation.counts?.[status] ?? 0), 0)
  const fromRequests = (automation.requests ?? [])
    .filter(request => normalizedStatuses.includes(normalizedScheduleStatus(request.effective_status ?? request.status)))
    .length
  return Math.max(fromCounts, fromRequests)
}

export function ScheduleSurface() {
  const data = toolsData.value
  const automation = data?.scheduled_automation ?? null
  const loading = toolsLoading.value
  const error = toolsError.value
  const dueEffective = automation?.derived_counts?.due_effective ?? 0
  // Shared with the nav badge + topbar chip so '승인 대기' has one derivation.
  const pendingCount = scheduledPendingApprovalCount(automation)
  const scheduledCount = countByStatus(automation, ['scheduled'])
  const runningCount = countByStatus(automation, ['running'])
  const dueRunning = dueEffective + runningCount
  const totalCount = automation?.requests?.length ?? 0

  // Detail-overlay selection is lifted here so the read-only operations aside
  // (right column) and the panel's cards/feed drive the same overlay.
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null)

  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }
  }, [])

  return html`
    <main class="ov ov-2col sch-surf" data-screen-label="예약" data-testid="schedule-surface">
      <div class="ov-scroll">
        <header class="ov-head" style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <span class="ov-eyebrow">Schedule</span>
            <h1>예약 · 자동화 큐</h1>
            <p class="ov-sub">
              keeper가 예약한 미래 작업 · operator가 due 전 승인 · <span class="mono">lib/schedule</span>
            </p>
            <div class="mt-2 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-testid="schedule-reality-notice">
              <${StatusChip} tone="warn" uppercase=${false}>관측 전용<//>
              <span>schedule runner projection을 읽어 표시하며, 이 화면에서 keeper turn을 자동 구동하지 않습니다.</span>
            </div>
          </div>
          <${ConnectionStatus} />
        </header>

        ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}

        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }} aria-label="예약 요약">
          <div class="ov-kpi">
            <div class="ov-kpi-k">승인 대기</div>
            <div class=${`ov-kpi-v ${pendingCount > 0 ? 'warn' : 'ok'}`}>${countLabel(pendingCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">예약됨</div>
            <div class=${`ov-kpi-v ${scheduledCount > 0 ? 'info' : ''}`}>${countLabel(scheduledCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">due · 실행</div>
            <div class=${`ov-kpi-v ${dueRunning > 0 ? 'warn' : ''}`}>${countLabel(dueRunning)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">총 예약</div>
            <div class="ov-kpi-v volt">${countLabel(totalCount)}</div>
          </div>
        </section>

        ${loading && !automation
          ? html`<${LoadingState}>예약 자동화 projection 불러오는 중...<//>`
          : html`<${ScheduledAutomationPanel}
              automation=${automation}
              variant="v2"
              selectedScheduleId=${selectedScheduleId}
              onSelectSchedule=${setSelectedScheduleId}
            />`}
      </div>
      ${automation
        ? html`<${ScheduleAside}
            requests=${automation.requests ?? []}
            sum=${{ scheduled: scheduledCount, dueRunning, pending: pendingCount, total: totalCount }}
            onOpen=${setSelectedScheduleId}
          />`
        : null}
    </main>
  `
}
