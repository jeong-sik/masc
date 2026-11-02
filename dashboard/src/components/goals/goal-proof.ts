import { html } from 'htm/preact'
import type { GoalProof, GoalProofCompletion } from '../../types/core'

function completionLabel(proof: GoalProofCompletion): string {
  switch (proof.state) {
    case 'idle': return '원장에 현재 요청 없음'
    case 'pending': return '검증 대기'
    case 'proven': return proof.confirmation ? `운영자 확인 · ${proof.confirmation.operatorId}` : '증명됨 · 최종 확인 대기'
    case 'refuted': return '반증됨'
  }
}

export function GoalProofStatus({ proof }: { proof: GoalProof | undefined }) {
  if (!proof || proof.state === 'unreadable') {
    const detail = proof?.detail ?? '검증 원장이 응답에 없습니다'
    return html`<span data-goal-proof="unreadable" title=${detail}>검증 · 확인 불가</span>`
  }
  if (proof.state === 'stale') {
    const old = proof.historical
    return html`<span data-goal-proof="stale" title=${`이전 기준 ${old.criterion.revision} · ${completionLabel(old)}. 현재 기준의 증명이 아닙니다.`}>검증 · 이전 기준의 기록</span>`
  }
  const current = proof.completion
  const detail = current.state === 'idle' ? '현재 원장에 검증 요청이 없습니다. 이전 실행의 종료 여부는 확인되지 않았습니다.'
    : current.state === 'pending' ? `요청 ${current.requestId} · 기준 ${current.criterion.revision}`
    : `${current.state === 'refuted' ? current.reason + '\n' : ''}${current.evidence}\n실행 ${current.runId} · 기준 ${current.criterion.revision}`
  return html`<span data-goal-proof=${current.state} title=${detail}>검증 · ${completionLabel(current)}</span>`
}


export function GoalProofDetail({ proof }: { proof: GoalProof | undefined }) {
  const refuted = proof?.state === 'current' && proof.completion.state === 'refuted'
    ? proof.completion : null
  return html`
    <section aria-label="Goal 검증 결과" class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-surface)] p-4 text-sm text-text-body">
      <${GoalProofStatus} proof=${proof} />
      ${refuted ? html`
        <p class="mt-2 whitespace-pre-wrap break-words">${refuted.reason}</p>
        <p class="mt-2 break-all text-xs text-text-muted">검증 실행 ${refuted.runId} · 기준 ${refuted.criterion.revision}</p>
      ` : null}
    </section>
  `
}
