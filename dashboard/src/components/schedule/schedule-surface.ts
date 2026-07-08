// Dedicated Schedule surface.
//
// Two views over one schedule projection (data.scheduled_automation):
//   · 캘린더 — the always-on polling strip (interval) above a day agenda
//     (scheduled + oneshot). Ported from the keeper-v2 prototype (schedule.jsx).
//   · 목록   — the mature diagnostic list/cards/signal feed in
//     tools/scheduled-automation-panel.ts (variant "v2"), reused verbatim so the
//     route does not fork the backed schedule semantics.
// A cadence filter (정기 · 폴링 · 1회) narrows both views. Both share one detail
// overlay (SchDetail) and one selection state, so a row opens the same drawer
// regardless of view.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { ConnectionStatus } from '../dashboard-shell'
import type { DashboardScheduledAutomation } from '../../api'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { StatusChip } from '../common/status-chip'
import { showToast } from '../common/toast'
import { KeeperLaneInventoryPanel } from '../tools/keeper-waiting-inventory-panel'
import { KeeperBackgroundPanel } from '../tools/keeper-background-panel'
import {
  ScheduleAside,
  ScheduledAutomationPanel,
  SchDetail,
  normalizedScheduleStatus,
  scheduledPendingApprovalCount,
} from '../tools/scheduled-automation-panel'
import type { Cadence } from '../v2/schedule-constants'
import { CadenceSummary, ScheduleCalendar, cadenceCounts, cadenceOfRequest } from './schedule-agenda'
import {
  loadTools,
  toolsData,
  toolsError,
  toolsLoading,
} from '../tools/tool-state'
import { pruneSchedules } from '../../api/dashboard-governance'

type ScheduleView = 'calendar' | 'list'

function countLabel(count: number): string {
  return count.toLocaleString()
}

// Narrow the projection handed to the list view so the cadence chip filters
// both views consistently. Requests and their durable signals are narrowed
// together (a signal for a filtered-out schedule would otherwise dangle).
function filterAutomationByCadence(
  automation: DashboardScheduledAutomation,
  cadence: Cadence | null,
): DashboardScheduledAutomation {
  if (cadence === null) return automation
  const requests = (automation.requests ?? []).filter(request => cadenceOfRequest(request) === cadence)
  const ids = new Set(requests.map(request => request.schedule_id))
  const signals = automation.signals?.filter(signal => ids.has(signal.schedule_id))
  return { ...automation, requests, signals }
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
  const waitingInventory = data?.keeper_waiting_inventory ?? null
  const keeperBackground = data?.keeper_background ?? null
  const loading = toolsLoading.value
  const error = toolsError.value
  const dueEffective = automation?.derived_counts?.due_effective ?? 0
  // Shared with the nav badge + topbar chip so '승인 대기' has one derivation.
  const pendingCount = scheduledPendingApprovalCount(automation)
  const scheduledCount = countByStatus(automation, ['scheduled'])
  const runningCount = countByStatus(automation, ['running'])
  const dueRunning = dueEffective + runningCount
  const requests = automation?.requests ?? []
  const totalCount = requests.length
  const cadCounts = cadenceCounts(requests)

  const [view, setView] = useState<ScheduleView>('calendar')
  const [cadenceFilter, setCadenceFilter] = useState<Cadence | null>(null)
  const [pruning, setPruning] = useState(false)
  // Detail-overlay selection is lifted here so the calendar view, the list
  // panel, and the operations aside all drive the same overlay.
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null)

  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) {
      void loadTools()
    }
  }, [])

  function switchView(next: ScheduleView) {
    // Clear selection so a drawer opened in one view does not linger into the
    // other (the list panel renders its own overlay from the same id).
    setSelectedScheduleId(null)
    setView(next)
  }

  const refresh = (): Promise<void> => loadTools()
  async function handlePrune() {
    if (
      !window.confirm(
        '완료되었거나 취소/만료/반려된 예약을 정리하시겠습니까?\n연관된 실행 기록 및 권한 승인도 함께 삭제됩니다.',
      )
    ) {
      return
    }
    setPruning(true)
    try {
      const result = await pruneSchedules()
      showToast(`완료된 예약 ${result.pruned_count.toLocaleString()}개를 정리했습니다.`, 'success')
      await refresh()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      console.error('[ScheduleSurface] prune failed:', error)
      showToast(message, 'error')
    } finally {
      setPruning(false)
    }
  }
  // In the calendar view the list panel is unmounted, so the surface owns the
  // overlay; the list panel renders its own overlay from the same selection.
  const selectedRequest =
    view === 'calendar' && selectedScheduleId
      ? requests.find(request => request.schedule_id === selectedScheduleId) ?? null
      : null

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
          <div class="flex flex-col items-end gap-2">
            <${ConnectionStatus} />
            <${ActionButton}
              variant="danger"
              size="sm"
              onClick=${handlePrune}
              disabled=${pruning}
              ariaBusy=${pruning}
              testId="schedule-prune-btn"
            >
              ${pruning ? '정리 중...' : '완료된 예약 정리'}
            <//>
          </div>
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

        <div class="sch-viewbar" data-testid="schedule-viewbar">
          <div class="sch-viewseg" role="tablist" aria-label="예약 뷰">
            <button
              type="button"
              role="tab"
              aria-selected=${view === 'calendar' ? 'true' : 'false'}
              class=${`sch-viewbtn ${view === 'calendar' ? 'on' : ''}`}
              data-testid="schedule-view-calendar"
              onClick=${() => switchView('calendar')}
            >▦ 캘린더</button>
            <button
              type="button"
              role="tab"
              aria-selected=${view === 'list' ? 'true' : 'false'}
              class=${`sch-viewbtn ${view === 'list' ? 'on' : ''}`}
              data-testid="schedule-view-list"
              onClick=${() => switchView('list')}
            >≡ 목록</button>
          </div>
          <${CadenceSummary} counts=${cadCounts} active=${cadenceFilter} onFilter=${setCadenceFilter} />
        </div>

        <section class="ov-card mt-4" aria-label="Keeper lane inventory" data-testid="schedule-keeper-lanes">
          <div class="ov-card-h"><h3>Keeper Lanes · wake evidence</h3></div>
          <${KeeperLaneInventoryPanel} inventory=${waitingInventory} />
        </section>

        <section class="ov-card mt-4" aria-label="Keeper background" data-testid="schedule-keeper-background">
          <div class="ov-card-h"><h3>Keeper Background · recurring tasks</h3></div>
          <${KeeperBackgroundPanel} background=${keeperBackground} />
        </section>

        ${loading && !automation
          ? html`<${LoadingState}>예약 자동화 projection 불러오는 중...<//>`
          : view === 'calendar'
            ? html`<${ScheduleCalendar}
                requests=${requests}
                nowMs=${Date.now()}
                cadenceFilter=${cadenceFilter}
                onOpen=${setSelectedScheduleId}
              />`
            : html`<${ScheduledAutomationPanel}
                automation=${automation ? filterAutomationByCadence(automation, cadenceFilter) : automation}
                variant="v2"
                onResolved=${refresh}
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
      ${selectedRequest
        ? html`<${SchDetail}
            request=${selectedRequest}
            onClose=${() => setSelectedScheduleId(null)}
            onResolved=${refresh}
          />`
        : null}
    </main>
  `
}
