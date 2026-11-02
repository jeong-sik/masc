import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { GoalCandleEpochMismatchError, GoalCandleWorkspaceRefusalError, readGoalCandle, type GoalCandleIssue, type GoalCandleObservation, type GoalCandlePayout } from '../../api/goal-candle'
import { ApiRequestError } from '../../api/core'
import { refreshExecution, resetExecutionSnapshotGeneration } from '../../store'
import type { ArtifactWorkspace } from '../../api/published-artifacts'

type Owner = { key: string; recoveryKey: string; goalId: string; workspace: ArtifactWorkspace; executionEpoch: string }
type View = { loading: boolean; value: GoalCandleObservation | null; error: string | null }
// A backend that alternates between incompatible generations must not make
// its remounting panel trigger an unbounded reconnect loop. A successful read
// or an explicit user retry permits one further automatic reconciliation.
const automaticRecoveryAttempted = new Set<string>()

function issueText(issue: GoalCandleIssue): string {
  switch (issue.kind) {
    case 'same_second': return `작업 ${issue.task_id} 완료와 ${issue.boundary === 'goal_created' ? '목표 생성' : '사람의 확인'}이 같은 초에 기록됨 (${issue.completed_at})`
    case 'task_missing': return `작업 ${issue.task_id}의 이전 상태를 찾을 수 없음`
    case 'task_unobserved': return `작업 ${issue.task_id}의 상태를 확인할 수 없음`
    case 'unfenced_nonterminal': return `작업 ${issue.task_id}의 과거 관측과 완료 순서를 확인할 수 없음`
    case 'reversed_window': return `목표 생성 ${issue.goal_created_at}과 확인 ${issue.confirmed_at}의 순서가 뒤바뀜`
  }
}
function milliCandle(amount: string): string {
  const digits = amount.padStart(4, '0')
  return `${digits.slice(0, -3)}.${digits.slice(-3)}`
}
function refusalText(error: ApiRequestError): string {
  if (error.status !== undefined && error.status >= 200 && error.status < 300)
    return `HTTP ${error.status} 응답 본문을 읽거나 해석할 수 없습니다.`
  const status = error.status === undefined ? '서버 응답을 확인할 수 없습니다.' : `서버 응답 HTTP ${error.status}.`
  return status + (error.status === 401 ? ' 인증을 확인한 뒤 다시 조회하세요.' : '')
}
function payoutText(payout: GoalCandlePayout): string {
  switch (payout.state) {
    case 'no_recorded_obligation': return '이 원장에 지급 의무가 기록되지 않았습니다. 과거 기록의 존재 여부까지 증명하지는 않습니다.'
    case 'inconsistent': return '지급 원장 상태를 해석할 수 없습니다.'
    case 'owed': return ({
      candidates_unrecorded: payout.snapshot === 'matching'
        ? '지급 의무가 기록되어 있으며 후보는 아직 기록되지 않았습니다. 대기 원인은 미관측입니다.'
        : '지급 의무가 기록되어 있으며 Snapshot을 확정할 수 없어 후보 준비가 진행되지 않습니다.',
      candidates_consistent: '지급 의무와 후보가 기록되어 있으며 지급을 기다립니다.',
      candidates_inconsistent: '지급 의무는 있으나 기록된 후보 증거가 일치하지 않아 지급 판단을 진행할 수 없습니다.',
      candidates_unchecked: '지급 의무와 후보가 기록되었으나 후보 증거의 일치 여부는 확인할 수 없습니다.',
    })[payout.stage]
    case 'held': return '기여 기간을 확정할 근거가 부족하여 지급이 보류되었습니다.'
    case 'paid': return `지급이 원장에 기록되었습니다 (${payout.recorded_at}).`
    case 'unattributed': return ({ no_candidates: '지급할 후보가 없다고 기록되었습니다.',
      all_unrelated: '후보 작업이 목표와 무관하다고 기록되었습니다.',
      no_related_keepers: '관련된 Keeper가 없다고 기록되었습니다.' })[payout.reason]
    case 'payout_failed': return '기한을 읽을 수 없다는 지급 실패가 원장에 기록되었습니다.'
  }
}

export function GoalCandlePanel({ owner, isCurrent, refreshKey }: {
  owner: Owner; isCurrent: () => boolean; refreshKey: string
}) {
  const [view, setView] = useState<View>({ loading: true, value: null, error: null })
  const active = useRef(false)
  const ticket = useRef(0)
  const ownerKey = useRef(owner.key)
  ownerKey.current = owner.key
  async function load() {
    if (!active.current || !isCurrent()) return
    const request = ++ticket.current
    const current = () => active.current && ownerKey.current === owner.key && request === ticket.current && isCurrent()
    // A response can carry a refusal or a new server epoch in its headers
    // while its body stalls. Until the whole response is checked, do not keep
    // drawing administrator-only data from the prior read.
    setView({ loading: true, value: null, error: null })
    const observed = { refusal: null as ApiRequestError | null, successStatus: null as number | null }
    try {
      const value = await readGoalCandle(owner.goalId, owner.workspace, owner.executionEpoch, error => {
        observed.refusal = error
        if (current()) setView({ loading: false, value: null, error: refusalText(error) })
      }, status => { observed.successStatus = status })
      if (current()) {
        automaticRecoveryAttempted.delete(owner.recoveryKey)
        setView({ loading: false, value, error: null })
      }
    } catch (error) {
      if (current()) {
        if (observed.refusal) {
          setView({ loading: false, value: null, error: refusalText(observed.refusal) })
          return
        }
        if (observed.successStatus !== null) {
          setView({ loading: false, value: null,
            error: `HTTP ${observed.successStatus} 응답 본문을 읽거나 해석할 수 없습니다.` })
          return
        }
        const workspaceChanged = error instanceof ApiRequestError && error.status === 409
          && error.errorCode === 'workspace_precondition_failed'
        const detail = error instanceof GoalCandleEpochMismatchError || error instanceof GoalCandleWorkspaceRefusalError
          ? error.message : error instanceof ApiRequestError ? refusalText(error)
            : '서버 응답을 확인할 수 없습니다. 연결을 확인한 뒤 다시 조회하세요.'
        setView({ loading: false, value: null, error: detail })
        if ((error instanceof GoalCandleEpochMismatchError || error instanceof GoalCandleWorkspaceRefusalError || workspaceChanged)
          && !automaticRecoveryAttempted.has(owner.recoveryKey)) {
          automaticRecoveryAttempted.add(owner.recoveryKey)
          resetExecutionSnapshotGeneration()
          void refreshExecution({ force: true }).catch(() => {})
        }
      }
    }
  }
  useEffect(() => {
    active.current = true
    void load()
    return () => { active.current = false; ticket.current++ }
  }, [owner.key, refreshKey])

  if (!isCurrent()) return null
  const ledger = view.value?.ledger
  const payout = ledger?.state === 'observed' ? ledger.payout : null
  return html`<section class="rounded border border-card-border p-4 min-w-0" aria-label="Candle 지급 기록" data-testid="goal-candle-panel">
    <div class="flex items-center justify-between gap-2">
      <h4 class="font-semibold">Candle 지급 기록</h4>
      <button type="button" class="text-xs underline" disabled=${view.loading} onClick=${() => {
        automaticRecoveryAttempted.delete(owner.recoveryKey)
        void load()
      }}>지급 기록 새로고침</button>
    </div>
    ${view.loading ? html`<p role="status">지급 기록을 확인하는 중...</p>` : null}
    ${view.error ? html`<p role="alert">지급 기록을 조회할 수 없습니다: ${view.error}</p>` : null}
    ${payout && 'request_id' in payout ? html`
      <p class="mt-1 text-xs text-text-muted">현재 후보 생성은 검증 기록 과정에서 저장한 Snapshot의 연결 작업만 읽습니다. 연결·삭제 이력 전체와 Snapshot 밖의 누락은 이 원장만으로 확인할 수 없습니다.</p>` : null}
    ${view.value ? html`<div class="mt-2 text-sm break-words">
      <p>마지막 조회 시 설정: ${{ enabled: '켜짐', off: '꺼짐', disabled: '설정 확인 불가' }[view.value.config]}</p>
      ${ledger?.state === 'missing' ? html`<p>원장 파일이 없습니다. 과거 기록의 삭제 또는 이동 여부는 미관측입니다.</p>` : null}
      ${ledger?.state === 'unavailable' ? html`<p>원장을 확인할 수 없습니다 (${{ locked: '잠김', unreadable: '읽기 실패', invalid_row: '유효하지 않은 행' }[ledger.reason]}).</p>` : null}
      ${payout ? html`<p data-candle-payout-state=${payout.state}>${payoutText(payout)}</p>` : null}
      ${payout && 'snapshot' in payout && payout.snapshot !== 'matching' ? html`
        <p>확인된 Snapshot: ${payout.snapshot === 'missing' ? '기록 없음' : '서로 다른 기록이 충돌함'}</p>` : null}
      ${payout && 'request_id' in payout ? html`<p class="text-xs text-text-muted">검증 요청 ${payout.request_id} · 실행 ${payout.verification_run_id}</p>` : null}
      ${payout?.state === 'paid' ? html`<div>
        <p>기록된 분배 (지급 당시 금액)</p>
        <ul>${payout.allocations.map(item => html`<li>${item.keeper}: ${milliCandle(item.amount_milli)} Candle · 가중치 ${item.weight}</li>`)}</ul>
        <p class="text-xs text-text-muted">현재 잔액은 이후의 감쇠와 거래에 따라 다를 수 있습니다.</p>
      </div>` : null}
      ${payout?.state === 'held' ? html`<div>
        <p class="text-xs text-text-muted">${payout.origin === 'stored' ? '원장에 기록된 보류' : '기록된 후보 관측에서 확인한 보류'}</p>
        ${payout.issues.state === 'unavailable' ? html`<p>보류의 세부 근거는 미관측입니다.</p>`
          : html`<ul>${payout.issues.entries.map(item => html`<li>${issueText(item)}</li>`)}</ul>`}
        ${payout.issues.state === 'snapshot_independent' ? html`<p>시간 경계의 추가 문제는 Snapshot을 확정할 수 없어 미관측입니다.</p>` : null}
        ${payout.origin === 'derived_candidates' ? html`<p>기록된 후보가 Snapshot의 모든 작업을 포함하는지와 후보 구성이 맞는지는 확인하지 않았습니다.</p>` : null}
      </div>` : null}
      <p class="mt-1 text-xs text-text-muted">모델 요청의 실행 여부는 이 원장만으로 확인할 수 없습니다.</p>
    </div>` : null}
  </section>`
}
