import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { confirmationBinding, readGoalConfirmation, sameConfirmationBinding, submitGoalConfirmation } from '../../api/goal-confirmation'
import type { GoalConfirmationEvidence } from '../../api/goal-confirmation'

type View =
  | { kind: 'loading' }
  | { kind: 'unavailable'; detail: string }
  | { kind: 'ready'; evidence: GoalConfirmationEvidence }
  | { kind: 'submitting'; evidence: GoalConfirmationEvidence }
  | { kind: 'uncertain'; evidence: GoalConfirmationEvidence; detail: string }
  | { kind: 'confirmed'; evidence: GoalConfirmationEvidence }
const message = (error: unknown) => error instanceof Error ? error.message : String(error)

export function GoalConfirmationPanel({ goalId, onConfirmed }: { goalId: string; onConfirmed: () => void }) {
  const [storedView, setView] = useState<View>({ kind: 'loading' })
  const view: View = 'evidence' in storedView && storedView.evidence.goalId !== goalId ? { kind: 'loading' } : storedView
  const generation = useRef(0)
  const currentGoal = useRef(goalId)
  currentGoal.current = goalId
  async function load() {
    const ticket = ++generation.current
    setView({ kind: 'loading' })
    try {
      const evidence = await readGoalConfirmation(goalId)
      if (ticket !== generation.current || currentGoal.current !== goalId) return
      setView(evidence.phase === 'completed' && evidence.proof.confirmation
        ? { kind: 'confirmed', evidence } : { kind: 'ready', evidence })
    } catch (error) {
      if (ticket === generation.current && currentGoal.current === goalId)
        setView({ kind: 'unavailable', detail: message(error) })
    }
  }
  useEffect(() => { void load(); return () => { generation.current++ } }, [goalId])
  async function confirm(evidence: GoalConfirmationEvidence) {
    const ticket = ++generation.current
    const binding = confirmationBinding(evidence)
    setView({ kind: 'submitting', evidence })
    try {
      const acknowledged = await submitGoalConfirmation(binding)
      if (!sameConfirmationBinding(acknowledged, binding) || acknowledged.phase !== 'completed' || !acknowledged.proof.confirmation)
        throw new Error('확인 응답이 제출한 증명 또는 완료 상태와 일치하지 않습니다')
      const readback = await readGoalConfirmation(goalId)
      if (!sameConfirmationBinding(readback, binding) || readback.phase !== 'completed' || !readback.proof.confirmation)
        throw new Error('확인 후 재조회에서 같은 증명의 완료를 확인하지 못했습니다')
      if (readback.proof.confirmation.operatorId !== acknowledged.proof.confirmation.operatorId
        || readback.proof.confirmation.confirmedAt !== acknowledged.proof.confirmation.confirmedAt)
        throw new Error('확인 응답과 재조회에서 운영자 확인 기록이 다릅니다')
      if (ticket !== generation.current || currentGoal.current !== goalId) return
      setView({ kind: 'confirmed', evidence: readback })
      onConfirmed()
    } catch (error) {
      if (ticket === generation.current && currentGoal.current === goalId)
        setView({ kind: 'uncertain', evidence, detail: message(error) })
    }
  }
  const evidence = 'evidence' in view ? view.evidence : null
  return html`<section class="rounded border border-card-border p-4 min-w-0" aria-label="목표 최종 확인" data-testid="goal-confirmation-panel">
    <h4 class="font-semibold">목표 최종 확인</h4>
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
    ${view.kind === 'ready' && view.evidence.phase === 'awaiting_confirmation' ? html`
      <p class="mt-2 text-sm">위 기준과 verifier 증거를 검토했습니다. 이 증명을 기준으로 목표 완료를 최종 확인합니다.</p>
      <button type="button" class="mt-2 rounded border px-3 py-2" onClick=${() => { void confirm(view.evidence) }}>이 증명으로 목표 완료 확인</button>` : null}
    ${view.kind === 'ready' && view.evidence.phase !== 'awaiting_confirmation' ? html`<p role="status">현재 단계는 최종 확인 대기가 아닙니다: ${view.evidence.phase}</p>` : null}
    ${view.kind === 'submitting' ? html`<p role="status">확인 응답과 저장된 결과를 재조회하는 중...</p>` : null}
    ${view.kind !== 'submitting' && view.kind !== 'loading' ? html`<button type="button" class="mt-2 rounded border px-3 py-2" onClick=${() => { void load() }}>현재 증거 다시 조회</button>` : null}
  </section>`
}
