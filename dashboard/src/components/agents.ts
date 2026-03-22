// 실행 표면 — 세션/작전 중심 실행 진단

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { RoomTruthStrip } from './common/room-truth-strip'
import {
  executionQueue,
  executionSessionBriefs,
  executionOperationBriefs,
  executionWorkerSupportBriefs,
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
} from './execution/workers'

export function Execution() {
  const queueRows = executionQueue.value
  const sessionRowsAll = executionSessionBriefs.value
  const operationRowsAll = executionOperationBriefs.value
  const workerSupportAll = executionWorkerSupportBriefs.value
  const continuityAll = executionContinuityBriefs.value
  const offlineRowsAll = executionOfflineWorkerBriefs.value

  const activeQueueId =
    selectedQueueId.value && queueRows.some(item => item.id === selectedQueueId.value)
      ? selectedQueueId.value
      : null
  const activeSelectedSessionId =
    selectedSessionId.value && sessionRowsAll.some(item => item.session_id === selectedSessionId.value)
      ? selectedSessionId.value
      : null
  const activeSelectedOperationId =
    selectedOperationId.value && operationRowsAll.some(item => item.operation_id === selectedOperationId.value)
      ? selectedOperationId.value
      : null

  useEffect(() => {
    if (selectedQueueId.value !== activeQueueId) {
      selectedQueueId.value = activeQueueId
    }
    if (selectedSessionId.value !== activeSelectedSessionId) {
      selectedSessionId.value = activeSelectedSessionId
    }
    if (selectedOperationId.value !== activeSelectedOperationId) {
      selectedOperationId.value = activeSelectedOperationId
    }
  }, [activeQueueId, activeSelectedSessionId, activeSelectedOperationId])

  const activeQueue = activeQueueId
    ? queueRows.find(item => item.id === activeQueueId) ?? null
    : null

  const activeSessionId = (() => {
    if (activeSelectedSessionId) return activeSelectedSessionId
    if (!activeQueue) return null
    if (activeQueue.kind === 'session') return activeQueue.target_id
    return activeQueue.linked_session_id ?? null
  })()

  const activeOperationId = (() => {
    if (activeSelectedOperationId) return activeSelectedOperationId
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
        title="주의 항목"
        class="section mb-3.5"
       
        testId="execution.queue"
      >
        ${allClear
          ? html`
              <div class="empty-state ok text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]" data-testid="execution.all-clear">
                정상 운영 중. 주의가 필요한 항목이 없습니다.
              </div>
            `
          : html`<${ExecutionQueueBody} queueRows=${queueRows} />`}
      <//>

      <div class="grid grid-cols-[minmax(0,1.08fr)_minmax(0,0.96fr)_minmax(0,0.88fr)] gap-4">
        <${Card}
          title="관련 세션"
          class="section mb-3.5"
         
          testId="execution.session-briefs"
        >
          <${SessionBriefsBody} sessionRows=${sessionRows} />
        <//>

        <${Card}
          title="관련 작업"
          class="section mb-3.5"
         
          testId="execution.operation-briefs"
        >
          <${OperationBriefsBody} operationRows=${operationRows} />
        <//>

        <${Card}
          title="참여 에이전트"
          class="section mb-3.5"
         
          testId="execution.worker-support"
        >
          <div class="monitor-list">
            ${workerSupportRows.length === 0
              ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">참여 에이전트가 없습니다.</div>`
              : workerSupportRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${Card}
          title="키퍼 연속성"
          class="section mb-3.5"
         
          testId="execution.continuity"
        >
          <div class="monitor-list">
            ${continuityRows.length === 0
              ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">연속성 경고 없음</div>`
              : continuityRows.map(row => html`<${ContinuityRow} key=${row.name} row=${row} />`)}
          </div>
        <//>

        <${Card}
          title="오프라인 에이전트"
          class="section mb-3.5"
         
          testId="execution.offline-workers"
        >
          <div class="monitor-list">
            ${offlineRows.length === 0
              ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">오프라인 에이전트 없음</div>`
              : offlineRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `
}

export const Agents = Execution
