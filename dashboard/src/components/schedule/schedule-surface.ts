// Dedicated Schedule surface.
//
// The card/detail projection lives in tools/scheduled-automation-panel.ts and
// is reused here so the route does not fork the backed schedule semantics.
// Shell (header + KPI strip) ported to the keeper-v2 prototype (schedule.jsx):
// `.ov.sch-surf` → `.ov-head` (eyebrow + title + sub) → `.ov-kpis` (4 KPIs).

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { DashboardToolsResponse, DashboardScheduledAutomation } from '../../api'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { KeeperWaitingInventoryPanel } from '../tools/keeper-waiting-inventory-panel'
import {
  SCHEDULE_RUNNING_STATUS_SET,
  SCHEDULE_SCHEDULED_STATUS_SET,
  ScheduleAside,
  ScheduledAutomationPanel,
  normalizedScheduleStatus,
  scheduledPendingApprovalCount,
} from '../tools/scheduled-automation-panel'
import {
  loadTools,
  toolsData,
  toolsError,
  toolsLoading,
} from '../tools/tool-state'

function countLabel(count: number | null): string {
  return count == null ? 'unknown' : count.toLocaleString()
}

function countByStatus(
  automation: DashboardScheduledAutomation | null,
  statuses: ReadonlySet<string>,
): number | null {
  if (!automation) return 0
  if (automation.schedule_store_known === false) return null
  const normalizedStatuses = [...statuses].map(normalizedScheduleStatus)
  const normalizedStatusSet = new Set(normalizedStatuses)
  const fromCounts = normalizedStatuses.reduce((sum, status) => sum + (automation.counts?.[status] ?? 0), 0)
  const fromRequests = (automation.requests ?? [])
    .filter(request => normalizedStatusSet.has(normalizedScheduleStatus(request.effective_status ?? request.status)))
    .length
  return Math.max(fromCounts, fromRequests)
}

function shortCommit(value: string | null | undefined): string {
  const trimmed = value?.trim()
  if (!trimmed) return 'unknown'
  return trimmed.length > 10 ? trimmed.slice(0, 10) : trimmed
}

interface RuntimeTruthNoticeModel {
  tone: StatusChipTone
  label: string
  summary: string
  detail: string
}

const BAD_RUNTIME_TRUTH_STATUSES: ReadonlySet<string> = new Set([
  'invalid',
  'error',
  'failed',
])

function runtimeTruthNotice(data: DashboardToolsResponse | null): RuntimeTruthNoticeModel | null {
  const runtime = data?.runtime_resolution ?? null
  const config = data?.config_resolution ?? null
  const reasons: string[] = []
  let bad = false
  if (config && config.status !== 'ready') reasons.push(`config ${config.status}`)
  if (runtime) {
    if (runtime.status !== 'ready') reasons.push(`runtime ${runtime.status}`)
    if (runtime.source_mismatch) {
      reasons.push('source mismatch')
      bad = true
    }
    if (runtime.server_workspace_mismatch) {
      reasons.push('server workspace mismatch')
      bad = true
    }
  }
  if (reasons.length === 0) return null
  const configStatus = config?.status ?? null
  const runtimeStatus = runtime?.status ?? null
  if (
    (configStatus != null && BAD_RUNTIME_TRUTH_STATUSES.has(configStatus))
    || (runtimeStatus != null && BAD_RUNTIME_TRUTH_STATUSES.has(runtimeStatus))
  ) {
    bad = true
  }
  const buildCommit = shortCommit(runtime?.build?.commit)
  const sourceCommit = shortCommit(runtime?.server_repo_git_commit ?? runtime?.workspace_git_commit)
  const startedAt = runtime?.build?.started_at ?? runtime?.generated_at ?? 'unknown'
  return {
    tone: bad ? 'bad' : 'warn',
    label: 'runtime truth',
    summary: reasons.join(' · '),
    detail: `build ${buildCommit} · source ${sourceCommit} · started ${startedAt}`,
  }
}

export function ScheduleSurface() {
  const data = toolsData.value
  const automation = data?.scheduled_automation ?? null
  const waitingInventory = data?.keeper_waiting_inventory ?? null
  const loading = toolsLoading.value
  const error = toolsError.value
  const scheduleStoreKnown = automation?.schedule_store_known !== false
  const dueEffective = scheduleStoreKnown ? (automation?.derived_counts?.due_effective ?? 0) : null
  // Shared with the nav badge + topbar chip so '승인 대기' has one derivation.
  const pendingCount = scheduledPendingApprovalCount(automation)
  const scheduledCount = countByStatus(automation, SCHEDULE_SCHEDULED_STATUS_SET)
  const runningCount = countByStatus(automation, SCHEDULE_RUNNING_STATUS_SET)
  const dueRunning = dueEffective == null || runningCount == null ? null : dueEffective + runningCount
  const totalCount = scheduleStoreKnown ? (automation?.requests?.length ?? 0) : null
  const runtimeNotice = runtimeTruthNotice(data)

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
        <header class="ov-head">
          <div>
            <span class="ov-eyebrow">Schedule</span>
            <h1>예약 · 자동화 큐</h1>
            <p class="ov-sub">
              keeper가 예약한 미래 작업 · operator가 due 전 승인 · <span class="mono">lib/schedule</span>
            </p>
            <div class="mt-2 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-testid="schedule-reality-notice">
              <${StatusChip} tone="warn" uppercase=${false}>운영자 승인<//>
              <span>승인·거부는 grant 결정을 기록하며, 이 화면에서 keeper turn을 직접 구동하지 않습니다.</span>
            </div>
            ${runtimeNotice
              ? html`
                  <div class="mt-2 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-testid="schedule-runtime-truth-notice">
                    <${StatusChip} tone=${runtimeNotice.tone} uppercase=${false}>${runtimeNotice.label}<//>
                    <span>${runtimeNotice.summary}</span>
                    <span class="mono text-[var(--color-fg-disabled)]">${runtimeNotice.detail}</span>
                  </div>
                `
              : null}
          </div>
        </header>

        ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}

        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }} aria-label="예약 요약">
          <div class="ov-kpi">
            <div class="ov-kpi-k">승인 대기</div>
            <div class=${`ov-kpi-v ${pendingCount != null && pendingCount > 0 ? 'warn' : pendingCount == null ? 'warn' : 'ok'}`}>${countLabel(pendingCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">예약됨</div>
            <div class=${`ov-kpi-v ${scheduledCount != null && scheduledCount > 0 ? 'info' : scheduledCount == null ? 'warn' : ''}`}>${countLabel(scheduledCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">due · 실행</div>
            <div class=${`ov-kpi-v ${dueRunning != null && dueRunning > 0 ? 'warn' : dueRunning == null ? 'warn' : ''}`}>${countLabel(dueRunning)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">총 예약</div>
            <div class="ov-kpi-v volt">${countLabel(totalCount)}</div>
          </div>
        </section>

        <section class="ov-card mt-4" aria-label="Keeper waiting inventory" data-testid="schedule-waiting-inventory">
          <div class="ov-card-h"><h3>Keeper Waiting Inventory</h3></div>
          <${KeeperWaitingInventoryPanel} inventory=${waitingInventory} />
        </section>

        ${loading && !automation
          ? html`<${LoadingState}>예약 자동화 projection 불러오는 중...<//>`
          : html`<${ScheduledAutomationPanel}
              automation=${automation}
              variant="v2"
              selectedScheduleId=${selectedScheduleId}
              onSelectSchedule=${setSelectedScheduleId}
              onResolved=${loadTools}
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
