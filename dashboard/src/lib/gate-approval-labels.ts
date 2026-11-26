// Operator wording for Gate approval rows, shared by the Approvals surface and
// the Work Inbox so one queue row reads the same on both screens.

import type { ApprovalQueuePhase, GateDecisionSource, GateJudgeLane } from '../types/gate'

export type ApprovalPhaseView = {
  key: ApprovalQueuePhase
  label: string
  detail: string
  severity: 'sev-info' | 'sev-warn' | 'sev-bad'
}

// A durable queue row can remain for hours after Auto Judge has already
// stopped. Project the closed summary/disposition states instead of calling
// every row "Human HITL": age is queue age, never model execution duration.
export function approvalPhaseView(phase: ApprovalQueuePhase): ApprovalPhaseView {
  switch (phase) {
    case 'blocked':
      return {
        key: 'blocked',
        label: '● Auto Judge blocked',
        detail: 'Auto Judge 종료 실패 · 재개나 Human 판단 필요',
        severity: 'sev-bad',
      }
    case 'human_required':
      return {
        key: 'human_required',
        label: '● Human required',
        detail: 'Auto Judge 완료 · Human 판단 필요',
        severity: 'sev-warn',
      }
    case 'judging':
      return {
        key: 'judging',
        label: '● Auto Judging',
        detail: 'Auto Judge 판정 중',
        severity: 'sev-info',
      }
    case 'queued':
      return {
        key: 'queued',
        label: '● Queue waiting',
        detail: '판정 시작 대기',
        severity: 'sev-warn',
      }
  }
}

export function decisionSourceLabel(source: GateDecisionSource | null | undefined): string {
  switch (source) {
    case 'always_allowed': return 'Always Allowed'
    case 'auto_judge': return 'Auto Judge'
    case 'human_operator': return 'Human'
    default: return '판단 주체 미확인'
  }
}

export function judgeLaneText(lane: GateJudgeLane): string {
  return lane.status === 'available'
    ? `판정 모델 ${lane.slots[0]}${lane.slots.length > 1 ? ` (+${lane.slots.length - 1} failover)` : ''}`
    : `판정 lane ${lane.lane_id} 확인 불가: ${lane.reason}`
}
