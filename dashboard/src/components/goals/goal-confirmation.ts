import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef, useState } from 'preact/hooks'
import { confirmationBinding, readGoalConfirmation, sameConfirmationBinding, submitGoalConfirmation } from '../../api/goal-confirmation'
import type { GoalConfirmationEvidence } from '../../api/goal-confirmation'
import type { ArtifactWorkspace } from '../../api/published-artifacts'

type View =
  | { kind: 'loading' }
  | { kind: 'unavailable'; detail: string }
  | { kind: 'ready'; evidence: GoalConfirmationEvidence }
  | { kind: 'submitting'; evidence: GoalConfirmationEvidence }
  | { kind: 'uncertain'; evidence: GoalConfirmationEvidence; detail: string }
  | { kind: 'confirmed'; evidence: GoalConfirmationEvidence }
const message = (error: unknown) => error instanceof Error ? error.message : String(error)

type ConfirmationOwner = { key: string; goalId: string; workspace: ArtifactWorkspace; credentialScope: string }
type Receipt = { owner: ConfirmationOwner; ticket: number; view: Extract<View, { kind: 'submitting' | 'uncertain' | 'confirmed' }> }
const receipts = signal<Record<string, Receipt>>({})
const uncertainHistory = signal<Record<string, Receipt[]>>({})
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
export function _testResetConfirmationReceipts() { receipts.value = {}; uncertainHistory.value = {} }

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

export function GoalConfirmationPanel({ owner, isCurrent, readAuthority, lifecyclePending, hasLifecyclePending, onConfirmed }: {
  owner: ConfirmationOwner; isCurrent: () => boolean; readAuthority: object
  lifecyclePending: boolean; hasLifecyclePending: () => boolean; onConfirmed: () => void
}) {
  const { goalId, workspace } = owner
  const [storedView, setView] = useState<View>({ kind: 'loading' })
  const [dismissedTicket, setDismissedTicket] = useState<number | null>(null)
  const [reviewedOther, setReviewedOther] = useState('')
  const generation = useRef(0)
  const active = useRef(false)
  const currentOwner = useRef(owner.key)
  currentOwner.current = owner.key
  const receipt = receipts.value[owner.key]
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
    setView({ kind: 'loading' })
    try {
      const evidence = await readGoalConfirmation(goalId, workspace)
      if (ticket !== generation.current || !current()) return
      setDismissedTicket(receipt?.ticket ?? null)
      if (explicit) setReviewedOther(otherUncertain)
      setView(evidence.phase === 'completed' && evidence.proof.confirmation
        ? { kind: 'confirmed', evidence } : { kind: 'ready', evidence })
    } catch (error) {
      if (ticket === generation.current && current()) {
        if (receipt?.view.kind === 'uncertain') {
          setReceipt({ ...receipt, view: { ...receipt.view, detail: `${receipt.view.detail} · 재조회 실패: ${message(error)}` } })
        } else {
          setDismissedTicket(receipt?.ticket ?? null)
          setView({ kind: 'unavailable', detail: message(error) })
        }
      }
    }
  }
  useEffect(() => {
    active.current = true
    if ((!receipt || receipt.view.kind === 'confirmed') && !otherPending) void load()
    return () => { active.current = false; generation.current++ }
  }, [owner.key, otherPending, otherUncertain, readAuthority])

  async function confirm(evidence: GoalConfirmationEvidence) {
    if (!current() || anotherRequestPending(owner) || hasLifecyclePending()
      || (otherUncertain && reviewedOther !== otherUncertain)
      || receipts.peek()[owner.key]?.view.kind === 'submitting') return
    const ticket = ++nextTicket
    const binding = confirmationBinding(evidence)
    setDismissedTicket(null)
    setReceipt({ owner, ticket, view: { kind: 'submitting', evidence } })
    try {
      // No await separates this authority check from constructing the POST.
      if (!current()) throw new Error('인증 또는 작업 공간이 변경되어 요청을 보내지 않았습니다')
      const acknowledged = await submitGoalConfirmation(binding)
      if (!sameConfirmationBinding(acknowledged, binding) || acknowledged.phase !== 'completed' || !acknowledged.proof.confirmation)
        throw new Error('확인 응답이 제출한 증명 또는 완료 상태와 일치하지 않습니다')
      if (!current()) throw new Error('원래 연결에서 확인 후 재조회가 필요합니다')
      const readback = await readGoalConfirmation(goalId, workspace)
      if (!sameConfirmationBinding(readback, binding) || readback.phase !== 'completed' || !readback.proof.confirmation)
        throw new Error('확인 후 재조회에서 같은 증명의 완료를 확인하지 못했습니다')
      if (readback.proof.confirmation.operatorId !== acknowledged.proof.confirmation.operatorId
        || readback.proof.confirmation.confirmedAt !== acknowledged.proof.confirmation.confirmedAt)
        throw new Error('확인 응답과 재조회에서 운영자 확인 기록이 다릅니다')
      if (!current()) throw new Error('원래 연결에서 확인 후 재조회가 필요합니다')
      if (receipts.peek()[owner.key]?.ticket !== ticket) return
      setReceipt({ owner, ticket, view: { kind: 'confirmed', evidence: readback } })
      onConfirmed()
    } catch (error) {
      if (receipts.peek()[owner.key]?.ticket === ticket)
        setReceipt({ owner, ticket, view: { kind: 'uncertain', evidence, detail: message(error) } })
    }
  }
  const evidence = 'evidence' in view ? view.evidence : null
  return html`<section class="rounded border border-card-border p-4 min-w-0" aria-label="목표 최종 확인" data-testid="goal-confirmation-panel">
    <h4 class="font-semibold">목표 최종 확인</h4>
    ${otherPending ? html`<p role="status">다른 연결 또는 인증의 같은 목표 확인이 끝나기를 기다리는 중입니다.</p>` : null}
    ${lifecyclePending ? html`<p role="status">같은 목표의 다른 변경 요청이 끝나기를 기다리는 중입니다.</p>` : null}
    ${otherUncertain ? html`<p role="status">다른 연결의 확인 요청 결과가 미확인입니다. 현재 증거를 확인한 뒤 결정해 주세요.</p>` : null}
    ${earlierUncertain.map(previous => previous.view.kind === 'uncertain' ? html`
      <p role="status">이전 확인 요청 결과 미확인 · 기준 ${previous.view.evidence.proof.criterion.revision}
        · 요청 ${previous.view.evidence.proof.requestId} · 실행 ${previous.view.evidence.proof.runId}
        · ${previous.view.detail}</p>` : null)}
    ${earlierPending.map(previous => previous.view.kind === 'submitting' ? html`
      <p role="status">이전 연결 확인 요청 진행 중 · 기준 ${previous.view.evidence.proof.criterion.revision}
        · 요청 ${previous.view.evidence.proof.requestId} · 실행 ${previous.view.evidence.proof.runId}</p>` : null)}
    ${view.kind === 'loading' ? html`<p role="status">인증된 verifier 증거를 불러오는 중...</p>` : null}
    ${view.kind === 'unavailable' ? html`<p role="alert">증거를 불러올 수 없습니다. 권한 또는 서버 응답을 확인하세요: ${view.detail}</p>` : null}
    ${evidence ? html`<dl class="mt-2 text-sm break-words">
      <dt>현재 성공 기준</dt><dd>${evidence.proof.criterion.title} · ${evidence.proof.criterion.metric} · 목표 ${evidence.proof.criterion.target_value}</dd>
      <dt>기준 revision</dt><dd>${evidence.proof.criterion.revision}</dd>
      <dt>Verifier 증거</dt><dd class="whitespace-pre-wrap">${evidence.proof.evidence}</dd>
      <dt>검증자</dt><dd>${evidence.proof.actor} · ${evidence.proof.recordedAt}</dd>
      <dt>검증 요청 / 실행</dt><dd>${evidence.proof.requestId} / ${evidence.proof.runId}</dd>
    </dl>` : null}
    ${view.kind === 'confirmed' ? html`<p role="status">최종 확인 완료 · ${view.evidence.proof.confirmation?.operatorId} · ${view.evidence.proof.confirmation?.confirmedAt}</p>` : null}
    ${view.kind === 'uncertain' ? html`<p role="alert">확인 요청을 보냈지만 완료 재확인이 필요합니다. 서버에 반영되었을 수 있습니다. ${view.detail}</p>` : null}
    ${view.kind === 'ready' && view.evidence.phase === 'awaiting_confirmation' && !otherPending && !lifecyclePending
      && (!otherUncertain || reviewedOther === otherUncertain) ? html`
      <p class="mt-2 text-sm">위 기준과 verifier 증거를 검토했습니다. 이 증명을 기준으로 목표 완료를 최종 확인합니다.</p>
      <button type="button" class="mt-2 rounded border px-3 py-2" onClick=${() => { void confirm(view.evidence) }}>이 증명으로 목표 완료 확인</button>` : null}
    ${view.kind === 'ready' && view.evidence.phase !== 'awaiting_confirmation' ? html`<p role="status">현재 단계는 최종 확인 대기가 아닙니다: ${view.evidence.phase}</p>` : null}
    ${view.kind === 'submitting' ? html`<p role="status">확인 응답과 저장된 결과를 재조회하는 중...</p>` : null}
    ${view.kind !== 'submitting' && view.kind !== 'loading' ? html`<button type="button" class="mt-2 rounded border px-3 py-2" onClick=${() => { void load(true) }}>현재 증거 다시 조회</button>` : null}
  </section>`
}
