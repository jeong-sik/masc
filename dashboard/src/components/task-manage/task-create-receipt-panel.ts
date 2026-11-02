import { html } from 'htm/preact'
import { ActionButton } from '../common/button'
import { acknowledgeTaskCreateResult, compactTaskCreateReceipts, recheckTaskCreation, retryTaskCreateStorage,
  taskCreateReceiptOwner, taskCreateReceipts, verifyTaskReceiptWorkspace } from './task-manage-state'
import type { TaskCreateAttempt, TaskCreationRead } from './task-create-receipt'

function readText(read: TaskCreationRead): string {
  switch (read.kind) {
    case 'not_observed': return '아직 생성 기록을 찾지 못했습니다. 요청이 진행 중일 수 있으므로 결과는 미확인입니다.'
    case 'recorded': return `${read.taskId}의 생성 기록을 확인했습니다. 현재 상태나 완료를 뜻하지는 않습니다.`
    case 'ambiguous': return `같은 요청의 생성 기록이 여러 건입니다: ${read.taskIds.join(', ')}`
    case 'error': return '생성 기록을 확인하지 못했습니다. 원래 요청의 결과는 그대로 보관합니다.'
  }
}

function attemptText(attempt: TaskCreateAttempt, canShow: boolean): string {
  if (!canShow) return '이전 요청이 있습니다. 현재 인증과 원래 작업 공간에서 결과를 확인해 주세요.'
  switch (attempt.original.kind) {
    case 'pending': return '태스크 생성 요청을 처리 중입니다.'
    case 'created': return `${attempt.original.taskId} 생성 응답을 받았습니다.`
    case 'not_sent': return '태스크 요청이 전송되지 않았습니다.'
    case 'rejected_before_effect': return '태스크 생성 전에 요청이 거부되었습니다.'
    case 'unconfirmed': return '태스크 생성 결과가 미확인입니다. 다시 요청하기 전에 생성 기록을 확인해 주세요.'
  }
}

export function TaskCreateReceiptsPanel() {
  const owner = taskCreateReceiptOwner.value
  const attempts = taskCreateReceipts.attempts.value.filter(item => item.original.kind === 'pending'
    || item.original.kind === 'unconfirmed' || (item.original.kind === 'created' && !item.presented)
    || item.reads.some(read => read.kind === 'ambiguous'))
  const storageState = taskCreateReceipts.storageState.value
  if (attempts.length === 0 && storageState !== 'write_failed') return null
  return html`<section aria-label="이전 태스크 생성 요청" class="rounded border border-card-border p-3">
    <h3 class="text-sm font-semibold">이전 태스크 생성 요청</h3>
    ${storageState === 'write_failed' ? html`<div role="alert" class="mt-2 text-xs text-text-muted">
      요청 기록을 저장하지 못했습니다. 저장을 다시 확인해 주세요.
      <${ActionButton} variant="ghost" size="sm" onClick=${retryTaskCreateStorage}>저장 다시 확인<//>
    </div>` : null}
    ${attempts.length > 0 ? html`<${ActionButton} variant="ghost" size="sm"
      onClick=${() => { void verifyTaskReceiptWorkspace() }}>현재 작업 공간 확인<//>` : null}
    ${attempts.map((attempt, index) => {
      const canIdentify = Boolean(owner && owner.isCurrent() && owner.workspace.basePath === attempt.workspace.basePath
        && owner.workspace.mascRoot === attempt.workspace.mascRoot)
      const canShow = canIdentify && (attempt.originalCurrent || attempt.latestReadCurrent)
      return html`<div key=${attempt.requestId} role="status" class="mt-2 text-xs text-text-muted">
        <p>요청 ${index + 1}${canIdentify ? ` · ${attempt.requestId} · ${attempt.createdAt}${attempt.goalId ? ` · Goal ${attempt.goalId}` : ''}` : ''}</p>
        <p>${attemptText(attempt, canShow)}</p>
        ${canShow && attempt.latestReadCurrent && attempt.reads.length > 0 ? html`<ol>
          ${attempt.reads.map((read, readIndex) => html`<li key=${readIndex}>${readText(read)}</li>`)}
        </ol>` : null}
        ${attempt.persistence === 'memory' ? html`<p>이 요청은 새로고침하면 이 탭에서 확인할 수 없습니다.</p>` : null}
        <${ActionButton} variant="ghost" size="sm" disabled=${attempt.checking}
          onClick=${() => { void recheckTaskCreation(attempt.requestId) }}>
          ${attempt.checking ? '확인 중...' : '결과 다시 확인'}
        <//>
        ${canShow && attempt.original.kind === 'created' && !attempt.presented ? html`<${ActionButton} variant="ghost" size="sm"
          onClick=${() => acknowledgeTaskCreateResult(attempt.requestId)}>이 결과 확인<//>` : null}
      </div>`
    })}
    <${ActionButton} variant="ghost" size="sm" onClick=${compactTaskCreateReceipts}>
      확인된 기록과 중복 조회 오류 정리
    <//>
    <p class="text-xs text-text-muted">미확정 요청과 모호한 결과는 보관하고, 같은 유형의 조회 오류는 가장 최근 기록을 남깁니다.</p>
  </section>`
}
