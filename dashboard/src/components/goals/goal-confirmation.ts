import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useLayoutEffect, useRef, useState } from 'preact/hooks'
import { confirmationBinding, readGoalConfirmation, sameConfirmationBinding, submitGoalConfirmation } from '../../api/goal-confirmation'
import type { GoalConfirmationEvidence } from '../../api/goal-confirmation'
import type { ArtifactWorkspace } from '../../api/published-artifacts'
import { ApiRequestError, getStoredToken } from '../../api/core'
import { recoverScopedRejectedCredential } from '../../api/dev-token'

type View =
  | { kind: 'loading' }
  | { kind: 'unavailable'; detail: string }
  | { kind: 'ready'; evidence: GoalConfirmationEvidence }
  | { kind: 'submitting'; evidence: GoalConfirmationEvidence; stage: 'sending' | 'readback' }
  | { kind: 'uncertain'; evidence: GoalConfirmationEvidence; detail: string; status: number | null }
  | { kind: 'confirmed'; evidence: GoalConfirmationEvidence }
const message = (error: unknown) => error instanceof Error ? error.message : String(error)

type ConfirmationOwner = { key: string; goalId: string; workspace: ArtifactWorkspace; credentialScope: string; executionEpoch: string }
type Receipt = { owner: ConfirmationOwner; ticket: number; view: Extract<View, { kind: 'submitting' | 'uncertain' | 'confirmed' }> }
const receipts = signal<Record<string, Receipt>>({})
const uncertainHistory = signal<Record<string, Receipt[]>>({})
const refusedAuthority = signal<Record<string, boolean>>({})
const refusalDetails = signal<Record<string, string>>({})
const refusalStatuses = signal<Record<string, number | null>>({})
type RefusalScope = { panel: object; readAuthority: object }
const refusalScopes = signal<Record<string, RefusalScope | null>>({})
let nextTicket = 0

function setReceipt(receipt: Receipt) {
  const previous = receipts.peek()[receipt.owner.key]
  if (previous?.view.kind === 'uncertain' && previous.ticket !== receipt.ticket) {
    uncertainHistory.value = { ...uncertainHistory.peek(), [receipt.owner.key]: [
      ...(uncertainHistory.peek()[receipt.owner.key] ?? []), previous,
    ] }
  }
  receipts.value = { ...receipts.peek(), [receipt.owner.key]: receipt }
}
export function _testResetConfirmationReceipts() {
  receipts.value = {}; uncertainHistory.value = {}; refusedAuthority.value = {}; refusalDetails.value = {}; refusalStatuses.value = {}; refusalScopes.value = {}
}

function setAuthorityRefused(key: string, refused: boolean, detail = '', status?: number, scope?: RefusalScope) {
  refusedAuthority.value = { ...refusedAuthority.peek(), [key]: refused }
  refusalDetails.value = { ...refusalDetails.peek(), [key]: detail }
  refusalStatuses.value = { ...refusalStatuses.peek(), [key]: refused ? (status ?? refusalStatuses.peek()[key] ?? null) : null }
  refusalScopes.value = { ...refusalScopes.peek(), [key]: refused ? (scope ?? refusalScopes.peek()[key] ?? null) : null }
}

function beginAuthorityRead(key: string) {
  refusedAuthority.value = { ...refusedAuthority.peek(), [key]: false }
  refusalDetails.value = { ...refusalDetails.peek(), [key]: '' }
  refusalStatuses.value = { ...refusalStatuses.peek(), [key]: null }
  refusalScopes.value = { ...refusalScopes.peek(), [key]: null }
}

const errorStatus = (error: unknown) => error instanceof ApiRequestError ? error.status : undefined
const recoverRefusal = (error: unknown, token: string | null, isCurrent: () => boolean,
  waitForCurrent?: () => Promise<boolean>) =>
  error instanceof ApiRequestError && error.status === 401 && token
    ? recoverScopedRejectedCredential({ token, authErrorCode: error.authErrorCode }, isCurrent, waitForCurrent)
    : Promise.resolve()

function anotherRequestPending(owner: ConfirmationOwner): boolean {
  return Object.values(receipts.peek()).some(receipt => receipt.owner.key !== owner.key
    && receipt.owner.goalId === owner.goalId
    && receipt.owner.workspace.basePath === owner.workspace.basePath
    && receipt.owner.workspace.mascRoot === owner.workspace.mascRoot
    && receipt.view.kind === 'submitting')
}

function otherUncertainTickets(owner: ConfirmationOwner): string {
  return [...Object.values(receipts.value), ...Object.values(uncertainHistory.value).flat()].filter(receipt => receipt.owner.key !== owner.key
    && receipt.owner.goalId === owner.goalId
    && receipt.owner.workspace.basePath === owner.workspace.basePath
    && receipt.owner.workspace.mascRoot === owner.workspace.mascRoot
    && receipt.view.kind === 'uncertain').map(receipt => receipt.ticket).sort((a, b) => a - b).join(',')
}

export function confirmationPending(workspace: ArtifactWorkspace, goalId: string): boolean {
  return Object.values(receipts.value).some(receipt => receipt.owner.goalId === goalId
    && receipt.owner.workspace.basePath === workspace.basePath && receipt.owner.workspace.mascRoot === workspace.mascRoot
    && receipt.view.kind === 'submitting')
}

export function confirmationHasUnsettledReceipt(workspace: ArtifactWorkspace, goalId: string): boolean {
  return [...Object.values(receipts.value), ...Object.values(uncertainHistory.value).flat()].some(receipt =>
    receipt.owner.goalId === goalId && receipt.owner.workspace.basePath === workspace.basePath
    && receipt.owner.workspace.mascRoot === workspace.mascRoot
    && (receipt.view.kind === 'submitting' || receipt.view.kind === 'uncertain'))
}

export function GoalConfirmationPanel({ owner, isCurrent, isRecoveryCurrent, waitForRecoveryCurrent, readAuthority, lifecyclePending, hasLifecyclePending, onConfirmed, onOutcome }: {
  owner: ConfirmationOwner; isCurrent: () => boolean; readAuthority: object
  isRecoveryCurrent?: () => boolean
  waitForRecoveryCurrent?: () => Promise<boolean>
  lifecyclePending: boolean; hasLifecyclePending: () => boolean; onConfirmed: () => void
  onOutcome?: (result: { ticket: number; state: 'pending' | 'confirmed' | 'uncertain' }) => void
}) {
  const { goalId, workspace } = owner
  const [storedView, setView] = useState<View>({ kind: 'loading' })
  const [dismissedTicket, setDismissedTicket] = useState<number | null>(null)
  const [reviewedOther, setReviewedOther] = useState('')
  const [verifiedOwner, setVerifiedOwner] = useState<{ key: string; readAuthority: object; evidence: GoalConfirmationEvidence } | null>(null)
  const [readingAuthority, setReadingAuthority] = useState<{ key: string; readAuthority: object; ticket: number } | null>(null)
  const generation = useRef(0)
  const panelScope = useRef<object>({}).current
  const active = useRef(false)
  const currentOwner = useRef(owner.key)
  currentOwner.current = owner.key
  const receipt = receipts.value[owner.key]
  const authorityRefused = refusedAuthority.value[owner.key] === true
  const authorityVerified = verifiedOwner?.key === owner.key && verifiedOwner.readAuthority === readAuthority && !authorityRefused
  const canReveal = (evidence: GoalConfirmationEvidence) => authorityVerified
    && evidence.goalId === owner.goalId
    && evidence.workspace.basePath === owner.workspace.basePath && evidence.workspace.mascRoot === owner.workspace.mascRoot
    && evidence.inspectionOperatorId === verifiedOwner?.evidence.inspectionOperatorId
    && evidence.runtimeInstanceId === verifiedOwner?.evidence.runtimeInstanceId
  const authorityReading = readingAuthority?.key === owner.key && readingAuthority.readAuthority === readAuthority
    && readingAuthority.ticket === generation.current
  const refusalDetail = refusalDetails.value[owner.key] ?? ''
  const refusalStatus = refusalStatuses.value[owner.key] ?? null
  const refusalScope = refusalScopes.value[owner.key]
  const refusalIsCurrent = refusalScope?.panel === panelScope && refusalScope.readAuthority === readAuthority
  const refuseAuthority = (detail: string, status?: number) =>
    setAuthorityRefused(owner.key, true, detail, status, { panel: panelScope, readAuthority })
  const otherPending = anotherRequestPending(owner)
  const otherUncertain = otherUncertainTickets(owner)
  const earlierUncertain = [ ...(uncertainHistory.value[owner.key] ?? []),
    ...(receipt?.view.kind === 'uncertain' && receipt.ticket === dismissedTicket ? [receipt] : []),
    ...[...Object.values(receipts.value), ...Object.values(uncertainHistory.value).flat()].filter(previous =>
      previous.owner.key !== owner.key && previous.owner.credentialScope === owner.credentialScope
      && previous.owner.goalId === owner.goalId && previous.owner.workspace.basePath === owner.workspace.basePath
      && previous.owner.workspace.mascRoot === owner.workspace.mascRoot && previous.view.kind === 'uncertain') ]
  const earlierPending = Object.values(receipts.value).filter(previous => previous.owner.key !== owner.key
    && previous.owner.credentialScope === owner.credentialScope && previous.owner.goalId === owner.goalId
    && previous.owner.workspace.basePath === owner.workspace.basePath && previous.owner.workspace.mascRoot === owner.workspace.mascRoot
    && previous.view.kind === 'submitting')
  const view = receipt && receipt.ticket !== dismissedTicket ? receipt.view : storedView
  const current = () => active.current && currentOwner.current === owner.key && isCurrent()

  async function load(explicit = false) {
    if (!current() || receipt?.view.kind === 'submitting' || anotherRequestPending(owner)) return
    if (otherUncertain && !explicit) {
      setView({ kind: 'unavailable', detail: '다른 연결에서 보낸 확인 요청의 결과가 미확인입니다. 현재 증거를 다시 조회해 주세요.' })
      return
    }
    const ticket = ++generation.current
    beginAuthorityRead(owner.key)
    setVerifiedOwner(null)
    setReadingAuthority({ key: owner.key, readAuthority, ticket })
    setView({ kind: 'loading' })
    const sentToken = getStoredToken()
    try {
      const evidence = await readGoalConfirmation(goalId, workspace, owner.executionEpoch, status => {
        if (ticket === generation.current && current()) refuseAuthority(
          status === undefined ? '서버 또는 작업 공간을 다시 확인해야 합니다' : '응답 내용을 확인하는 중입니다', status)
      })
      if (ticket !== generation.current || !current()) return
      setAuthorityRefused(owner.key, false)
      setVerifiedOwner({ key: owner.key, readAuthority, evidence })
      setDismissedTicket(receipt?.ticket ?? null)
      if (explicit) setReviewedOther(otherUncertain)
      setView(evidence.phase === 'completed' && evidence.proof.confirmation
        ? { kind: 'confirmed', evidence } : { kind: 'ready', evidence })
    } catch (error) {
      if (ticket === generation.current && current()) {
        const detail = '증거 조회에 실패했습니다. 연결과 권한, 저장소 상태를 확인한 뒤 다시 조회해 주세요.'
        refuseAuthority(detail, errorStatus(error))
        if (receipt?.view.kind === 'uncertain') {
          setReceipt({ ...receipt, view: { ...receipt.view, detail: `${receipt.view.detail} · 재조회 실패` } })
        } else {
          setDismissedTicket(receipt?.ticket ?? null)
          setView({ kind: 'unavailable', detail })
        }
        void recoverRefusal(error, sentToken, () => ticket === generation.current && current())
      }
    } finally {
      if (ticket === generation.current && current()) setReadingAuthority(null)
    }
  }
  useLayoutEffect(() => {
    active.current = true
    if ((!receipt || receipt.view.kind === 'confirmed' || receipt.ticket === dismissedTicket) && !otherPending) void load()
    return () => { active.current = false; generation.current++ }
  }, [owner.key, otherPending, otherUncertain, readAuthority])

  async function confirm(evidence: GoalConfirmationEvidence) {
    if (!current() || anotherRequestPending(owner) || hasLifecyclePending()
      || (otherUncertain && reviewedOther !== otherUncertain)
      || receipts.peek()[owner.key]?.view.kind === 'submitting') return
    const ticket = ++nextTicket
    const binding = confirmationBinding(evidence)
    let readbackStarted = false
    setDismissedTicket(null)
    setReceipt({ owner, ticket, view: { kind: 'submitting', evidence, stage: 'sending' } })
    onOutcome?.({ ticket, state: 'pending' })
    const sentToken = getStoredToken()
    try {
      // No await separates this authority check from constructing the POST.
      if (!current()) throw new Error('인증 또는 작업 공간이 변경되어 요청을 보내지 않았습니다')
      const acknowledged = await submitGoalConfirmation(binding, status => {
        if (receipts.peek()[owner.key]?.ticket === ticket) refuseAuthority(
          status === undefined ? '서버를 다시 확인해야 합니다' : '응답 내용을 확인하는 중입니다', status)
      })
      if (!sameConfirmationBinding(acknowledged, binding) || acknowledged.phase !== 'completed' || !acknowledged.proof.confirmation)
        throw new Error('확인 응답이 제출한 증명 또는 완료 상태와 일치하지 않습니다')
      if (!current()) throw new Error('원래 연결에서 확인 후 재조회가 필요합니다')
      if (receipts.peek()[owner.key]?.ticket !== ticket) return
      setReceipt({ owner, ticket, view: { kind: 'submitting', evidence, stage: 'readback' } })
      readbackStarted = true
      const readback = await readGoalConfirmation(goalId, workspace, owner.executionEpoch, status => {
        if (receipts.peek()[owner.key]?.ticket === ticket) refuseAuthority(
          status === undefined ? '서버 또는 작업 공간을 다시 확인해야 합니다' : '응답 내용을 확인하는 중입니다', status)
      })
      if (!sameConfirmationBinding(readback, binding) || readback.phase !== 'completed' || !readback.proof.confirmation)
        throw new Error('확인 후 재조회에서 같은 증명의 완료를 확인하지 못했습니다')
      if (readback.proof.confirmation.operatorId !== acknowledged.proof.confirmation.operatorId
        || readback.proof.confirmation.confirmedAt !== acknowledged.proof.confirmation.confirmedAt)
        throw new Error('확인 응답과 재조회에서 운영자 확인 기록이 다릅니다')
      if (!current()) throw new Error('원래 연결에서 확인 후 재조회가 필요합니다')
      if (receipts.peek()[owner.key]?.ticket !== ticket) return
      setReceipt({ owner, ticket, view: { kind: 'confirmed', evidence: readback } })
      onOutcome?.({ ticket, state: 'confirmed' })
      onConfirmed()
    } catch (error) {
      if (receipts.peek()[owner.key]?.ticket === ticket) {
        refuseAuthority('확인 요청의 결과를 다시 조회해 주세요.', errorStatus(error))
        setReceipt({ owner, ticket, view: { kind: 'uncertain', evidence,
          detail: readbackStarted ? '확인 후 재조회에 실패했습니다.' : message(error),
          status: errorStatus(error) ?? refusalStatuses.peek()[owner.key] ?? null } })
        // Start recovery under the original owner, then immediately withdraw
        // the old tree. Never replay the POST after a credential change.
        const recovery = recoverRefusal(error, sentToken, () =>
          (isRecoveryCurrent ? isRecoveryCurrent() : current()) && receipts.peek()[owner.key]?.ticket === ticket,
        waitForRecoveryCurrent ? async () => await waitForRecoveryCurrent() && receipts.peek()[owner.key]?.ticket === ticket : undefined)
        onOutcome?.({ ticket, state: 'uncertain' })
        void recovery.catch(error => console.warn('[goal-confirmation] credential recovery failed', error))
      }
    }
  }
  const evidence = 'evidence' in view && canReveal(view.evidence) ? view.evidence : null
  return html`<section class="rounded border border-card-border p-4 min-w-0" aria-label="목표 최종 확인" data-testid="goal-confirmation-panel">
    <h4 class="font-semibold">목표 최종 확인</h4>
    ${otherPending ? html`<p role="status">다른 연결 또는 인증의 같은 목표 확인이 끝나기를 기다리는 중입니다.</p>` : null}
    ${lifecyclePending ? html`<p role="status">같은 목표의 다른 변경 요청이 끝나기를 기다리는 중입니다.</p>` : null}
    ${otherUncertain ? html`<p role="status">다른 연결의 확인 요청 결과가 미확인입니다. 현재 증거를 확인한 뒤 결정해 주세요.</p>` : null}
    ${earlierUncertain.map(previous => previous.view.kind === 'uncertain' ? html`
      <p role="status">이전 확인 요청 결과 미확인 · 요청 기록 ${previous.ticket}${canReveal(previous.view.evidence) ? html`
        · 기준 ${previous.view.evidence.proof.criterion.revision} · 요청 ${previous.view.evidence.proof.requestId}
        · 실행 ${previous.view.evidence.proof.runId} · ${previous.view.detail}` : null}${previous.view.status === null ? '' : ` · HTTP ${previous.view.status}`}</p>` : null)}
    ${earlierPending.map(previous => previous.view.kind === 'submitting' ? html`
      <p role="status">이전 연결 확인 요청 진행 중 · 요청 기록 ${previous.ticket}${canReveal(previous.view.evidence) ? html`
        · 기준 ${previous.view.evidence.proof.criterion.revision} · 요청 ${previous.view.evidence.proof.requestId}
        · 실행 ${previous.view.evidence.proof.runId}` : null}</p>` : null)}
    ${authorityRefused ? html`<p role="alert">${refusalIsCurrent
      ? '현재 증거를 다시 확인할 수 없어 이전 증거를 숨겼습니다. 요청 기록은 보존됩니다.'
      : '이전 요청에서 오류가 발생했습니다. 현재 증거를 다시 조회해 주세요.'}
      ${refusalStatus === null ? '' : `HTTP ${refusalStatus} · `}${refusalIsCurrent ? refusalDetail : ''}</p>` : null}
    ${!authorityVerified && !authorityRefused && authorityReading && view.kind !== 'loading'
      ? html`<p role="status">현재 증거의 접근 권한을 다시 확인하는 중입니다.</p>` : null}
    ${!authorityVerified && !authorityRefused && !authorityReading && view.kind !== 'loading'
      ? html`<p role="status">현재 증거를 다시 조회해 주세요.</p>` : null}
    ${view.kind === 'loading' && authorityReading ? html`<p role="status">인증된 verifier 증거를 불러오는 중...</p>` : null}
    ${view.kind === 'loading' && !authorityReading && !otherPending ? html`<p role="status">현재 증거를 다시 조회해 주세요.</p>` : null}
    ${view.kind === 'unavailable' ? html`<p role="alert">증거를 불러올 수 없습니다. 권한 또는 서버 응답을 확인하세요.${authorityVerified ? ` ${view.detail}` : ''}</p>` : null}
    ${evidence ? html`<dl class="mt-2 text-sm break-words">
      <dt>현재 성공 기준</dt><dd>${evidence.proof.criterion.title} · ${evidence.proof.criterion.metric} · 목표 ${evidence.proof.criterion.target_value}</dd>
      <dt>기준 revision</dt><dd>${evidence.proof.criterion.revision}</dd>
      <dt>Verifier 증거</dt><dd class="whitespace-pre-wrap">${evidence.proof.evidence}</dd>
      <dt>검증자</dt><dd>${evidence.proof.actor} · ${evidence.proof.recordedAt}</dd>
      <dt>검증 요청 / 실행</dt><dd>${evidence.proof.requestId} / ${evidence.proof.runId}</dd>
    </dl>` : null}
    ${evidence?.phase === 'awaiting_confirmation' && evidence.proof.confirmation ? html`<p role="status">
      운영자 확인은 이미 기록되었습니다 · ${evidence.proof.confirmation.operatorId} · ${evidence.proof.confirmation.confirmedAt}.
      목표 완료와 후속 처리는 아직 확인되지 않았습니다. 같은 증명의 완료 처리를 재개할 수 있습니다.</p>` : null}
    ${view.kind === 'confirmed' && canReveal(view.evidence) ? html`<p role="status">최종 확인 완료 · ${view.evidence.proof.confirmation?.operatorId} · ${view.evidence.proof.confirmation?.confirmedAt}</p>` : null}
    ${view.kind === 'uncertain' ? html`<p role="alert">확인 요청을 보냈지만 완료 재확인이 필요합니다. 서버에 반영되었을 수 있습니다.
      ${view.status !== null && (!refusalIsCurrent || refusalStatus !== view.status) ? `이전 확인 응답 HTTP ${view.status}` : ''}
      ${canReveal(view.evidence) ? view.detail : ''}</p>` : null}
    ${view.kind === 'ready' && canReveal(view.evidence) && view.evidence.phase === 'awaiting_confirmation' && !otherPending && !lifecyclePending
      && (!otherUncertain || reviewedOther === otherUncertain) ? html`
      <p class="mt-2 text-sm">${view.evidence.proof.confirmation
        ? '위 기준과 저장된 확인을 검토했습니다. 같은 증명의 완료 처리를 재개합니다.'
        : '위 기준과 verifier 증거를 검토했습니다. 이 증명을 기준으로 목표 완료를 최종 확인합니다.'}</p>
      <p class="mt-2 text-xs text-text-muted">현재 Candle 후보 생성은 증명 기록 중 저장된 Snapshot의 연결 작업만 읽습니다. 연결·삭제 이력 전체와 Snapshot 밖의 지급 누락 여부는 확인되지 않았습니다.</p>
      <button type="button" class="mt-2 rounded border px-3 py-2" onClick=${() => { void confirm(view.evidence) }}>${view.evidence.proof.confirmation
        ? '이 증명의 완료 처리 재개' : '이 증명으로 목표 완료 확인'}</button>` : null}
    ${view.kind === 'ready' && canReveal(view.evidence) && view.evidence.phase !== 'awaiting_confirmation' ? html`<p role="status">현재 단계는 최종 확인 대기가 아닙니다: ${view.evidence.phase}</p>` : null}
    ${view.kind === 'submitting' ? html`<p role="status">${authorityRefused
      ? '확인 요청의 오류 응답을 읽는 중입니다.' : view.stage === 'sending'
        ? '확인 요청의 응답을 기다리는 중입니다.' : '저장된 확인 결과를 다시 조회하는 중입니다.'}</p>` : null}
    ${view.kind !== 'submitting' && !authorityReading && !otherPending ? html`<button type="button" class="mt-2 rounded border px-3 py-2" onClick=${() => { void load(true) }}>현재 증거 다시 조회</button>` : null}
  </section>`
}
