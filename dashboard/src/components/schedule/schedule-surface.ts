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
import type { DashboardScheduledAutomation } from '../../api'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { StatusChip } from '../common/status-chip'
import { showToast } from '../common/toast'
import { KeeperLaneInventoryPanel } from '../tools/keeper-waiting-inventory-panel'
import { KeeperBackgroundPanel } from '../tools/keeper-background-panel'
import {
  ScheduleAside,
  ScheduleProjectionNotice,
  ScheduledAutomationPanel,
  SchDetail,
  normalizedScheduleStatus,
} from '../tools/scheduled-automation-panel'
import type { Cadence } from '../v2/schedule-constants'
import { CadenceSummary, ScheduleCalendar, cadenceCounts, cadenceOfRequest } from './schedule-agenda'
import { countQueueDrainMisses } from './queue-drain-status'
import {
  loadTools,
  toolsData,
  toolsError,
  toolsLoading,
} from '../tools/tool-state'
import { pruneSchedules } from '../../api/dashboard-schedule'

type ScheduleView = 'calendar' | 'list'

function countLabel(count: number): string {
  return count.toLocaleString()
}

function exactCountLabel(count: number | null): string {
  return count == null ? '알 수 없음' : countLabel(count)
}

// Narrow the projection handed to the list view so the cadence chip filters
// both views consistently. Requests and their durable signals are narrowed
// together (a signal for a filtered-out schedule would otherwise dangle).
function filterAutomationByCadence(
  automation: DashboardScheduledAutomation,
  cadence: Cadence | null,
): DashboardScheduledAutomation {
  if (cadence === null || automation.schedule_store_known === false) return automation
  const requests = (automation.requests ?? []).filter(request => cadenceOfRequest(request) === cadence)
  const ids = new Set(requests.map(request => request.schedule_id))
  const signals = automation.signals.filter(signal => ids.has(signal.schedule_id))
  return { ...automation, requests, signals }
}

function countByStatus(
  automation: DashboardScheduledAutomation | null,
  statuses: readonly string[],
): number | null {
  if (!automation || automation.schedule_store_known === false) {
    return null
  }
  const normalizedStatuses = statuses.map(normalizedScheduleStatus)
  return normalizedStatuses.reduce((sum, status) => sum + (automation.counts[status] ?? 0), 0)
}

type ScheduleProjectionIntegrity =
  | { status: 'valid' }
  | { status: 'invalid'; errors: string[] }

function scheduleProjectionIntegrity(
  automation: DashboardScheduledAutomation | null,
): ScheduleProjectionIntegrity {
  if (!automation || automation.schedule_store_known === false) return { status: 'valid' }
  const projection = automation.request_projection
  const errors: string[] = []
  if (projection.returned_count !== automation.requests.length) {
    errors.push(`returned_count=${projection.returned_count} rows=${automation.requests.length}`)
  }
  if (projection.returned_count > projection.total_count) {
    errors.push(`returned_count=${projection.returned_count} total_count=${projection.total_count}`)
  }
  if (projection.truncated !== (projection.returned_count < projection.total_count)) {
    errors.push(
      `truncated=${String(projection.truncated)} returned_count=${projection.returned_count} total_count=${projection.total_count}`,
    )
  }
  const projectedCounts = new Map<string, number>()
  for (const request of automation.requests) {
    const status = normalizedScheduleStatus(request.status)
    projectedCounts.set(status, (projectedCounts.get(status) ?? 0) + 1)
  }
  for (const [status, projectedCount] of projectedCounts) {
    const exactCount = automation.counts[status] ?? 0
    if (projectedCount > exactCount) {
      errors.push(`status=${status} projected=${projectedCount} exact=${exactCount}`)
    }
  }
  if (!automation.payload_support) {
    errors.push('payload_support projection is missing')
  } else {
    const visibleUnsupported = automation.requests.filter(
      request => request.payload_support === 'unsupported',
    ).length
    const visibleUnknown = automation.requests.filter(
      request => request.payload_support === 'unknown',
    ).length
    if (visibleUnsupported > automation.payload_support.unsupported_request_count) {
      errors.push(
        `payload_support=unsupported projected=${visibleUnsupported} exact=${automation.payload_support.unsupported_request_count}`,
      )
    }
    if (visibleUnknown > automation.payload_support.unknown_request_count) {
      errors.push(
        `payload_support=unknown projected=${visibleUnknown} exact=${automation.payload_support.unknown_request_count}`,
      )
    }
  }
  return errors.length === 0 ? { status: 'valid' } : { status: 'invalid', errors }
}

export function ScheduleSurface() {
  const data = toolsData.value
  const automation = data?.scheduled_automation ?? null
  const waitingInventory = data?.keeper_waiting_inventory ?? null
  const keeperBackground = data?.keeper_background ?? null
  const loading = toolsLoading.value
  const error = toolsError.value
  const scheduledCount = countByStatus(automation, ['scheduled'])
  const dueCount = countByStatus(automation, ['due'])
  const runningCount = countByStatus(automation, ['running'])
  const dueRunning = dueCount == null || runningCount == null ? null : dueCount + runningCount
  const requests = automation?.requests ?? []
  const totalCount = automation?.request_projection.total_count ?? null
  const cadCounts = cadenceCounts(requests)
  // Scheduled keeper wakes that were dispatched but are in neither queue AND
  // never recorded as reacted — the drain-miss the calendar surfaces per row.
  const queueMisses = automation?.schedule_store_known === false
    || automation?.request_projection.truncated === true
    ? null
    : countQueueDrainMisses(requests)
  const projectionIntegrity = scheduleProjectionIntegrity(automation)

  const [view, setView] = useState<ScheduleView>('calendar')
  const [cadenceFilter, setCadenceFilter] = useState<Cadence | null>(null)
  const [pruning, setPruning] = useState(false)
  // Detail-overlay selection is lifted here so the calendar view, the list
  // panel, and the operations aside all drive the same overlay.
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null)
  // Keeper-lane wake evidence + background are large operator diagnostics
  // (a card per keeper, dozens of lane rows). Collapsed AND unmounted by default
  // so the schedule stays the light, primary content; the panels only mount when
  // the operator opens them.
  const [diagOpen, setDiagOpen] = useState(false)

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
        '완료되었거나 취소/만료된 예약을 정리하시겠습니까?\n연관된 실행 기록도 함께 삭제됩니다.',
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
        <header class="ov-head">
          <div>
            <span class="ov-eyebrow">Schedule</span>
            <h1>예약 · 자동화 큐</h1>
            <p class="ov-sub">
              keeper가 예약한 미래 작업 · <span class="mono">lib/schedule</span>
            </p>
            <div
              class="mt-2 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]"
              data-testid="schedule-reality-notice"
              title="schedule runner projection을 읽어 표시하며, 이 화면에서 keeper turn을 자동 구동하지 않습니다."
            >
              <${StatusChip} tone="warn" uppercase=${false}>관측 전용<//>
              <span class="sr-only">schedule runner projection을 읽어 표시하며, 이 화면에서 keeper turn을 자동 구동하지 않습니다.</span>
            </div>
          </div>
        </header>

        ${error ? html`<${ErrorState} message=${error} class="mb-4" />` : null}
        ${projectionIntegrity.status === 'invalid'
          ? html`<${ErrorState}
              message=${`schedule projection integrity failure: ${projectionIntegrity.errors.join('; ')}`}
              class="mb-4"
            />`
          : null}

        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }} aria-label="예약 요약">
          <div class="ov-kpi">
            <div class="ov-kpi-k">예약됨</div>
            <div class=${`ov-kpi-v ${scheduledCount != null && scheduledCount > 0 ? 'info' : ''}`}>${exactCountLabel(scheduledCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">due · 실행</div>
            <div class=${`ov-kpi-v ${dueRunning != null && dueRunning > 0 ? 'warn' : ''}`}>${exactCountLabel(dueRunning)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">총 예약</div>
            <div class="ov-kpi-v volt">${exactCountLabel(totalCount)}</div>
          </div>
          <div class="ov-kpi" data-testid="schedule-kpi-queue-miss">
            <div class="ov-kpi-k">큐 누락</div>
            <div
              class=${`ov-kpi-v ${queueMisses == null ? '' : queueMisses > 0 ? 'warn' : 'ok'}`}
              title=${automation?.request_projection.truncated === true
                ? '예약 행 projection이 일부이므로 전체 큐 누락 수는 알 수 없습니다.'
                : 'dispatch됐으나 큐(pending·inflight)에도 없고 keeper 반응 기록도 없는 예약 실행 수 — 실행 누락'}
            >${exactCountLabel(queueMisses)}</div>
          </div>
        </section>

        ${automation?.schedule_store_known === false ? null : html`<div class="sch-viewbar" data-testid="schedule-viewbar">
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
        </div>`}

        ${view === 'calendar' && automation
          ? html`<${ScheduleProjectionNotice} automation=${automation} />`
          : null}

        ${loading && !automation
          ? html`<${LoadingState}>예약 자동화 projection 불러오는 중...<//>`
          : automation?.schedule_store_known === false
            ? html`
                <div
                  class="rounded border border-[var(--color-status-bad)]/40 bg-[var(--color-bg-surface)] px-4 py-3 text-xs text-[var(--color-fg-muted)]"
                  data-schedule-store-unavailable="true"
                >
                  schedule store를 읽지 못해 예약 행·상태·실행 대기 여부를 판단할 수 없습니다.
                </div>
              `
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
                selectedScheduleId=${selectedScheduleId}
                onSelectSchedule=${setSelectedScheduleId}
              />`}

        ${'' /* Secondary diagnostics live BELOW the schedule and are unmounted
              until opened: the actual schedule (calendar/list) is the primary,
              above-the-fold content. The keeper-lane wake evidence + background
              panels are large operator diagnostics (a card per keeper, dozens of
              lane rows) that previously buried the schedule and rendered on every
              tick. Lazy-mounting them keeps the default surface light. */}
        <section class="ov-card mt-4 sch-diag" data-testid="schedule-diagnostics">
          <button
            type="button"
            class="sch-diag-summary"
            aria-expanded=${diagOpen ? 'true' : 'false'}
            data-testid="schedule-diagnostics-toggle"
            onClick=${() => setDiagOpen(open => !open)}
          >Keeper 진단 · wake evidence · background ${diagOpen ? '▴' : '▾'}</button>
          ${diagOpen
            ? html`
                <div class="sch-diag-actions">
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
                <section class="mt-3" aria-label="Keeper lane inventory" data-testid="schedule-keeper-lanes">
                  <div class="ov-card-h"><h3>Keeper Lanes · wake evidence</h3></div>
                  <${KeeperLaneInventoryPanel} inventory=${waitingInventory} />
                </section>

                <section class="mt-4" aria-label="Keeper background" data-testid="schedule-keeper-background">
                  <div class="ov-card-h"><h3>Keeper Background · recurring tasks</h3></div>
                  <${KeeperBackgroundPanel} background=${keeperBackground} />
                </section>
              `
            : null}
        </section>
      </div>
      ${automation
        ? html`<${ScheduleAside}
            requests=${automation.requests ?? []}
            sum=${{ scheduled: scheduledCount, dueRunning, total: totalCount }}
            onOpen=${setSelectedScheduleId}
          />`
        : null}
      ${selectedRequest
        ? html`<${SchDetail}
            request=${selectedRequest}
            onClose=${() => setSelectedScheduleId(null)}
          />`
        : null}
    </main>
  `
}
