// Dedicated Schedule surface.
//
// Two views over one schedule projection, read from the shared schedule
// resource (GET /api/v1/dashboard/scheduled-automation):
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
import {
  fetchDashboardScheduledAutomationLookup,
  type DashboardScheduledAutomationLookup,
} from '../../api/dashboard-scheduled-automation'
import { replaceRoute, route } from '../../router'
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
  scheduleWireValue,
} from '../tools/scheduled-automation-panel'
import type { Cadence } from '../v2/schedule-constants'
import { CadenceSummary, ScheduleCalendar, cadenceCounts, cadenceOfRequest } from './schedule-agenda'
import { countQueueDrainCancelled, countQueueDrainMisses } from './queue-drain-status'
import {
  loadTools,
  toolsData,
} from '../tools/tool-state'
import {
  loadScheduledAutomation,
  scheduledAutomationError,
  scheduledAutomationLoading,
  scheduledAutomationProjection,
  subscribeScheduledAutomationRefresh,
} from './schedule-state'
import { pruneSchedules } from '../../api/dashboard-schedule'

type ScheduleView = 'calendar' | 'list'

type ExactScheduleState =
  | { kind: 'idle' }
  | { kind: 'loading'; scheduleId: string }
  | { kind: 'resolved'; lookup: DashboardScheduledAutomationLookup }
  | { kind: 'failed'; scheduleId: string; reason: string }

function countLabel(count: number | null): string {
  return count === null ? '—' : count.toLocaleString()
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
  automation: DashboardScheduledAutomation,
  statuses: readonly string[],
): number {
  const wireStatuses = statuses.map(scheduleWireValue)
  const fromCounts = wireStatuses.reduce(
    (sum, status) => sum + (automation.counts?.[status] ?? 0),
    0,
  )
  const fromRequests = (automation.requests ?? [])
    .filter(request => wireStatuses.includes(scheduleWireValue(request.status)))
    .length
  return Math.max(fromCounts, fromRequests)
}

export function ScheduleSurface() {
  const data = toolsData.value
  // Schedule rows come from the schedule projection; the keeper diagnostics
  // panels below still read the tool inventory, which is why both are loaded.
  const projection = scheduledAutomationProjection.value
  const automation = projection?.state === 'available' ? projection.data : null
  const page = projection?.state === 'available' ? projection.page : null
  const projectionError = projection?.state === 'unavailable' ? projection.reason : null
  const waitingInventory = data?.keeper_waiting_inventory ?? null
  const keeperBackground = data?.keeper_background ?? null
  const loading = scheduledAutomationLoading.value
  const error = scheduledAutomationError.value
  const blockingError = automation ? null : projectionError ?? error
  const scheduledCount = automation ? countByStatus(automation, ['scheduled']) : null
  const dueCount = automation ? countByStatus(automation, ['due']) : null
  const runningCount = automation ? countByStatus(automation, ['running']) : null
  const dueRunning = dueCount === null || runningCount === null
    ? null
    : dueCount + runningCount
  const requests = automation?.requests ?? []
  const routeScheduleId = route.value.params.schedule_id ?? null
  const inPageRequest = routeScheduleId === null
    ? null
    : requests.find(request => request.schedule_id === routeScheduleId) ?? null
  const totalCount = page?.totalCount ?? null
  const cadCounts = cadenceCounts(requests)
  // Scheduled keeper wakes that were dispatched but are in neither queue AND
  // never recorded as reacted — the drain-miss the calendar surfaces per row.
  const queueMisses = automation ? countQueueDrainMisses(requests) : null
  // Wakes the queue cancelled without a turn — a definition whose target is
  // gone keeps firing into this number every day.
  const queueCancelled = automation ? countQueueDrainCancelled(requests) : null
  // Every retained attempt in the store, not the newest of the rows on the
  // page: a burst of failures a later tick retried is still counted here.
  const wakeCounts = automation?.wake_counts ?? null

  const [view, setView] = useState<ScheduleView>('calendar')
  const [cadenceFilter, setCadenceFilter] = useState<Cadence | null>(null)
  const [pruning, setPruning] = useState(false)
  const selectedScheduleId = routeScheduleId
  const [exactSchedule, setExactSchedule] = useState<ExactScheduleState>({ kind: 'idle' })
  // Keeper-lane wake evidence + background are large operator diagnostics
  // (a card per keeper, dozens of lane rows). Collapsed AND unmounted by default
  // so the schedule stays the light, primary content; the panels only mount when
  // the operator opens them.
  const [diagOpen, setDiagOpen] = useState(false)

  useEffect(() => {
    const stopScheduleRefresh = subscribeScheduledAutomationRefresh()
    // Tool inventory is still needed for the keeper waiting/background panels.
    if (!toolsData.value) void loadTools()
    return stopScheduleRefresh
  }, [])

  useEffect(() => {
    if (
      selectedScheduleId === null
      || projection?.state !== 'available'
      || inPageRequest !== null
    ) {
      setExactSchedule({ kind: 'idle' })
      return
    }
    const controller = new AbortController()
    setExactSchedule({ kind: 'loading', scheduleId: selectedScheduleId })
    void fetchDashboardScheduledAutomationLookup(selectedScheduleId, {
      signal: controller.signal,
    })
      .then(lookup => { setExactSchedule({ kind: 'resolved', lookup }) })
      .catch((error: unknown) => {
        if (controller.signal.aborted) return
        setExactSchedule({
          kind: 'failed',
          scheduleId: selectedScheduleId,
          reason: error instanceof Error ? error.message : String(error),
        })
      })
    return () => { controller.abort() }
  }, [selectedScheduleId, projection?.state, inPageRequest !== null])

  function selectSchedule(scheduleId: string | null) {
    const params = { ...route.value.params }
    if (scheduleId === null) delete params.schedule_id
    else params.schedule_id = scheduleId
    replaceRoute('schedule', params)
  }

  function switchView(next: ScheduleView) {
    // Clear selection so a drawer opened in one view does not linger into the
    // other (the list panel renders its own overlay from the same id).
    selectSchedule(null)
    setView(next)
  }

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
      await loadScheduledAutomation({ fresh: true })
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
  const exactRequest =
    exactSchedule.kind === 'resolved'
    && exactSchedule.lookup.status === 'found'
    && exactSchedule.lookup.scheduleId === selectedScheduleId
      ? exactSchedule.lookup.request
      : null
  const selectedRequest =
    view === 'calendar' && selectedScheduleId !== null
      ? inPageRequest ?? exactRequest
      : null
  const exactLookupMessage = (() => {
    if (selectedScheduleId === null) return null
    if (exactSchedule.kind === 'loading' && exactSchedule.scheduleId === selectedScheduleId) {
      return '정확한 예약을 조회하는 중입니다.'
    }
    if (exactSchedule.kind === 'failed' && exactSchedule.scheduleId === selectedScheduleId) {
      return exactSchedule.reason
    }
    if (
      exactSchedule.kind !== 'resolved'
      || exactSchedule.lookup.scheduleId !== selectedScheduleId
      || exactSchedule.lookup.status === 'found'
    ) return null
    return exactSchedule.lookup.status === 'not_found'
      ? 'schedule store에서 정확한 예약을 찾지 못했습니다.'
      : exactSchedule.lookup.reason
  })()

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

        ${error || projectionError
          ? html`
              <div data-testid=${projectionError ? 'schedule-projection-unavailable' : undefined}>
                <${ErrorState} message=${error ?? projectionError ?? ''} class="mb-4" />
              </div>
            `
          : null}

        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(6, 1fr)' }} aria-label="예약 요약">
          <div class="ov-kpi">
            <div class="ov-kpi-k">예약됨</div>
            <div class=${`ov-kpi-v ${scheduledCount !== null && scheduledCount > 0 ? 'info' : ''}`}>${countLabel(scheduledCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">due · 실행</div>
            <div class=${`ov-kpi-v ${dueRunning !== null && dueRunning > 0 ? 'warn' : ''}`}>${countLabel(dueRunning)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">총 예약</div>
            <div class="ov-kpi-v volt">${countLabel(totalCount)}</div>
          </div>
          <div class="ov-kpi" data-testid="schedule-kpi-queue-miss">
            <div class="ov-kpi-k">큐 누락</div>
            <div
              class=${`ov-kpi-v ${queueMisses === null ? '' : queueMisses > 0 ? 'warn' : 'ok'}`}
              title="dispatch됐으나 pending 큐에도 없고 keeper 반응 기록도 없는 예약 실행 수 — 실행 누락"
            >${countLabel(queueMisses)}</div>
          </div>
          <div class="ov-kpi" data-testid="schedule-kpi-queue-cancelled">
            <div class="ov-kpi-k">큐 취소</div>
            <div
              class=${`ov-kpi-v ${queueCancelled === null ? '' : queueCancelled > 0 ? 'warn' : 'ok'}`}
              title="마지막 wake 를 큐가 accepted cancellation 으로 정리한 예약 수 — keeper 턴 없이 끝남 (대상 keeper 부재 포함)"
            >${countLabel(queueCancelled)}</div>
          </div>
          <div class="ov-kpi" data-testid="schedule-kpi-wake-failed">
            <div class="ov-kpi-k">wake 실패</div>
            <div
              class=${`ov-kpi-v ${wakeCounts === null ? '' : wakeCounts.failed > 0 ? 'warn' : 'ok'}`}
              title=${wakeCounts === null
                ? 'store 의 보존된 wake 를 서버가 세어 보내지 않음'
                : `보존된 wake ${wakeCounts.retained}건(예약당 최대 ${wakeCounts.retention_per_schedule}) 중 실패 ${wakeCounts.failed} · 성공 ${wakeCounts.succeeded} · 진행 ${wakeCounts.running} · 살아있는 예약 중 마지막 wake 실패 ${wakeCounts.active_with_failed_newest_wake}`}
            >${countLabel(wakeCounts === null ? null : wakeCounts.failed)}</div>
          </div>
        </section>

        ${page
          ? html`
              <div class="mb-3 text-2xs text-[var(--color-fg-muted)]" data-testid="schedule-page-metadata">
                ${`표시 ${page.visibleCount.toLocaleString()} / 전체 ${page.totalCount.toLocaleString()} · 최대 ${page.limit.toLocaleString()}${page.truncated ? ' · 일부만 표시' : ''}`}
              </div>
            `
          : null}

        ${exactLookupMessage
          ? html`
              <div class="ov-card mb-3 text-xs text-[var(--color-fg-muted)]" data-testid="schedule-exact-lookup-status">
                <span class="mono">${selectedScheduleId}</span> · ${exactLookupMessage}
              </div>
            `
          : null}

        ${blockingError
          ? html`
              <div class="ov-card mb-4 text-sm text-[var(--color-fg-muted)]" data-testid="schedule-ledger-unknown">
                schedule projection을 확인할 수 없어 예약 수와 일정을 표시할 수 없습니다.
              </div>
            `
          : html`<div class="sch-viewbar" data-testid="schedule-viewbar">
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
        </div>`}

        ${blockingError
          ? null
          : loading && !automation
          ? html`<${LoadingState}>예약 자동화 projection 불러오는 중...<//>`
          : view === 'calendar'
            ? html`<${ScheduleCalendar}
                requests=${requests}
                nowMs=${Date.now()}
                cadenceFilter=${cadenceFilter}
                onOpen=${selectSchedule}
              />`
            : html`<${ScheduledAutomationPanel}
                automation=${automation ? filterAutomationByCadence(automation, cadenceFilter) : automation}
                variant="v2"
                selectedScheduleId=${selectedScheduleId}
                selectedRequest=${inPageRequest ?? exactRequest}
                onSelectSchedule=${selectSchedule}
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
      ${automation && scheduledCount !== null && dueRunning !== null && totalCount !== null
        ? html`<${ScheduleAside}
            requests=${automation.requests ?? []}
            sum=${{ scheduled: scheduledCount, dueRunning, total: totalCount }}
            onOpen=${selectSchedule}
          />`
        : null}
      ${selectedRequest
        ? html`<${SchDetail}
            request=${selectedRequest}
            signals=${automation?.signals ?? []}
            onClose=${() => selectSchedule(null)}
          />`
        : null}
    </main>
  `
}
