import { html } from 'htm/preact'
import type { GoalProof, GoalProofCompletion } from '../../types/core'

function completionLabel(proof: GoalProofCompletion): string {
  switch (proof.state) {
    case 'idle': return '미제출'
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
    return html`<span data-goal-proof="stale" title=${`이전 기준 ${old.criterion.revision} · ${completionLabel(old)}. 현재 기준의 증명이 아닙니다.`}>검증 · 기준 변경 · 재검증 필요</span>`
  }
  const current = proof.completion
  const detail = current.state === 'idle' ? '아직 검증을 요청하지 않았습니다'
    : current.state === 'pending' ? `요청 ${current.requestId} · 기준 ${current.criterion.revision}`
    : `${current.state === 'refuted' ? current.reason + '\n' : ''}${current.evidence}\n실행 ${current.runId} · 기준 ${current.criterion.revision}`
  return html`<span data-goal-proof=${current.state} title=${detail}>검증 · ${completionLabel(current)}</span>`
}
