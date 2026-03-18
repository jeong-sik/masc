// 실행 표면 — 세션/작전 중심 실행 진단

import { html } from 'htm/preact'
import { Card } from './common/card'
import { RoomTruthStrip } from './common/room-truth-strip'
import {
  executionQueue,
  executionSessionBriefs,
  executionOperationBriefs,
  executionWorkerSupportBriefs,
  executionLodgeTick,
  executionLodgeCheckins,
  executionContinuityBriefs,
  executionOfflineWorkerBriefs,
  executionLoaded,
} from '../store'
import {
  selectedQueueId,
  selectedSessionId,
  selectedOperationId,
} from './execution/shared'
import { ExecutionQueueBody } from './execution/queue'
import { SessionBriefsBody } from './execution/sessions'
import { OperationBriefsBody } from './execution/operations'
import {
  WorkerSupportRow,
  ContinuityRow,
  LodgeTickCard,
  LodgeCheckinRow,
} from './execution/workers'

export function Execution() {
  const queueRows = executionQueue.value
  const sessionRowsAll = executionSessionBriefs.value
  const operationRowsAll = executionOperationBriefs.value
  const workerSupportAll = executionWorkerSupportBriefs.value
  const lodgeTick = executionLodgeTick.value
  const lodgeCheckinsAll = executionLodgeCheckins.value
  const continuityAll = executionContinuityBriefs.value
  const offlineRowsAll = executionOfflineWorkerBriefs.value

  if (selectedQueueId.value && !queueRows.some(item => item.id === selectedQueueId.value)) {
    selectedQueueId.value = null
  }
  if (selectedSessionId.value && !sessionRowsAll.some(item => item.session_id === selectedSessionId.value)) {
    selectedSessionId.value = null
  }
  if (selectedOperationId.value && !operationRowsAll.some(item => item.operation_id === selectedOperationId.value)) {
    selectedOperationId.value = null
  }

  const activeQueue = selectedQueueId.value
    ? queueRows.find(item => item.id === selectedQueueId.value) ?? null
    : null

  const activeSessionId = (() => {
    if (selectedSessionId.value) return selectedSessionId.value
    if (!activeQueue) return null
    if (activeQueue.kind === 'session') return activeQueue.target_id
    return activeQueue.linked_session_id ?? null
  })()

  const activeOperationId = (() => {
    if (selectedOperationId.value) return selectedOperationId.value
    if (!activeQueue) return null
    if (activeQueue.kind === 'operation') return activeQueue.target_id
    return activeQueue.linked_operation_id ?? null
  })()

  const sessionRows =
    activeSessionId
      ? sessionRowsAll.filter(item => item.session_id === activeSessionId)
      : activeOperationId
        ? sessionRowsAll.filter(item => item.linked_operation_id === activeOperationId)
        : sessionRowsAll

  const operationRows =
    activeOperationId
      ? operationRowsAll.filter(item => item.operation_id === activeOperationId)
      : activeSessionId
        ? operationRowsAll.filter(item => item.linked_session_id === activeSessionId || item.operation_id === sessionRows[0]?.linked_operation_id)
        : operationRowsAll

  const workerSupportRows =
    activeSessionId || activeOperationId
      ? workerSupportAll.filter(item =>
          (activeSessionId ? item.related_session_id === activeSessionId : false)
          || (activeOperationId ? item.related_operation_id === activeOperationId : false))
      : workerSupportAll

  const continuityRows =
    activeSessionId
      ? continuityAll.filter(item => item.related_session_id === activeSessionId || item.tone !== 'ok')
      : continuityAll

  const lodgeCheckins =
    activeSessionId
      ? lodgeCheckinsAll.filter(item =>
          sessionRows.some(row => row.member_names.includes(item.agent_name)))
      : lodgeCheckinsAll

  const offlineRows =
    activeSessionId || activeOperationId
      ? offlineRowsAll.filter(item =>
          (activeSessionId ? item.related_session_id === activeSessionId : false)
          || (activeOperationId ? item.related_operation_id === activeOperationId : false)
          || item.tone !== 'ok')
      : offlineRowsAll

  const allClear =
    executionLoaded.value
    && queueRows.length === 0
    && sessionRowsAll.length === 0
    && operationRowsAll.length === 0

  return html`
    <div class="agents-monitor">
      <${RoomTruthStrip} />
      <${Card}
        title="실행 대기열"
        class="section"
        semanticId="execution.queue"
        testId="execution.queue"
      >
        ${allClear
          ? html`
              <div class="empty-state ok" data-testid="execution.all-clear">
                모든 실행이 정상입니다. 개입이 필요한 항목이 없습니다.
              </div>
            `
          : html`<${ExecutionQueueBody} queueRows=${queueRows} />`}
      <//>

      <div class="agents-workbench">
        <${Card}
          title="영향받는 세션"
          class="section"
          semanticId="execution.sessions"
          testId="execution.session-briefs"
        >
          <${SessionBriefsBody} sessionRows=${sessionRows} />
        <//>

        <${Card}
          title="영향받는 작전"
          class="section"
          semanticId="execution.operations"
          testId="execution.operation-briefs"
        >
          <${OperationBriefsBody} operationRows=${operationRows} />
        <//>

        <${Card}
          title="Social Activity"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Social Activity</h2>
            <p class="monitor-subheadline">최근 public-square 이벤트에서 어떤 keeper가 행동했고, 어떤 keeper가 판단상 패스했으며, 어떤 경우가 시스템에 의해 스킵됐는지 먼저 보여줍니다.</p>
          </div>
          <${LodgeTickCard} tick=${lodgeTick} />
          <div class="monitor-list">
            ${lodgeCheckins.length === 0
              ? html`<div class="empty-state">최근 social activity 기록이 없습니다.</div>`
              : lodgeCheckins.map(row => html`<${LodgeCheckinRow} key=${`${row.agent_name}-${row.checked_at ?? row.outcome}`} row=${row} />`)}
          </div>
        <//>

        <${Card}
          title="작업 인력"
          class="section"
          semanticId="execution.worker_support"
          testId="execution.worker-support"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">지원 작업자</h2>
            <p class="monitor-subheadline">선택된 세션이나 작전에 연결된 작업자만 보이고, 전체 작업자 벽은 첫 화면을 차지하지 않게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${workerSupportRows.length === 0
              ? html`<div class="empty-state">연결된 작업자가 없습니다.</div>`
              : workerSupportRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${Card}
          title="연속성"
          class="section"
          semanticId="execution.continuity"
          testId="execution.continuity"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">키퍼 연속성 요약</h2>
            <p class="monitor-subheadline">카드 제목은 keeper 이름이고, keeper-*-agent 형태의 runtime agent는 보조 라벨로만 표시합니다.</p>
          </div>
          <div class="monitor-list">
            ${continuityRows.length === 0
              ? html`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`
              : continuityRows.map(row => html`<${ContinuityRow} key=${row.name} row=${row} />`)}
          </div>
        <//>

        <${Card}
          title="오프라인 인력"
          class="section"
          semanticId="execution.offline"
          testId="execution.offline-workers"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">오프라인 작업자</h2>
            <p class="monitor-subheadline">빠진 작업자는 하단 보조 면으로 분리해 활성 실행 판단을 방해하지 않게 유지합니다.</p>
          </div>
          <div class="monitor-list">
            ${offlineRows.length === 0
              ? html`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`
              : offlineRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `
}

export const Agents = Execution
