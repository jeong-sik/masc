// HumanInTheLoop — AX molecule for agent approval requests.
//
// Kimi design system sec05 reference: Google AI Human-in-the-loop pattern.
// Risk-level styling + countdown timer + approve/reject/modify actions.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'

export type ApprovalRiskLevel = 'low' | 'medium' | 'high' | 'critical'

export interface ApprovalRequest {
  id: string
  agentId: string
  action: string
  details: string
  riskLevel: ApprovalRiskLevel
  timeoutSeconds: number
  requestedAt: number
}

export interface RiskConfig {
  border: string
  bg: string
  label: string
}

export interface HumanInTheLoopSummary {
  readonly requestId: string
  readonly agentId: string
  readonly agentShort: string
  readonly riskLevel: ApprovalRiskLevel
  readonly riskLabel: string
  readonly isCritical: boolean
  readonly timeoutSeconds: number
  readonly remainingSeconds: number
  readonly countdown: string
  readonly expired: boolean
  readonly actionLength: number
  readonly detailsLength: number
  readonly hasDetails: boolean
}

const RISK_CONFIG: Record<ApprovalRiskLevel, RiskConfig> = {
  low: {
    border: 'border-[var(--color-status-ok)]/40',
    bg: 'bg-[var(--color-status-ok)]/12',
    label: '낮은 위험',
  },
  medium: {
    border: 'border-[var(--color-status-warn)]/40',
    bg: 'bg-[var(--color-status-warn)]/12',
    label: '중간 위험',
  },
  high: {
    border: 'border-[var(--color-status-err)]/40',
    bg: 'bg-[var(--color-status-err)]/12',
    label: '높은 위험',
  },
  critical: {
    border: 'border-[var(--color-status-err)]/60',
    bg: 'bg-[var(--color-status-err)]/20',
    label: '심각한 위험',
  },
}

export function riskConfig(riskLevel: ApprovalRiskLevel): RiskConfig {
  return RISK_CONFIG[riskLevel]
}

export function formatCountdown(totalSeconds: number): string {
  const safeSeconds = Math.max(0, Math.floor(totalSeconds))
  const m = Math.floor(safeSeconds / 60)
  const s = safeSeconds % 60
  return `${m}:${s.toString().padStart(2, '0')}`
}

export function summarizeHumanInTheLoop(
  request: ApprovalRequest,
  remainingSeconds = request.timeoutSeconds,
): HumanInTheLoopSummary {
  const risk = riskConfig(request.riskLevel)
  const normalizedRemaining = Math.max(0, Math.floor(remainingSeconds))

  return {
    requestId: request.id,
    agentId: request.agentId,
    agentShort: request.agentId.slice(0, 8),
    riskLevel: request.riskLevel,
    riskLabel: risk.label,
    isCritical: request.riskLevel === 'critical',
    timeoutSeconds: request.timeoutSeconds,
    remainingSeconds: normalizedRemaining,
    countdown: formatCountdown(normalizedRemaining),
    expired: normalizedRemaining === 0,
    actionLength: request.action.length,
    detailsLength: request.details.length,
    hasDetails: request.details.length > 0,
  }
}

interface HumanInTheLoopProps {
  request: ApprovalRequest
  onApprove: (id: string) => void
  onReject: (id: string) => void
  onModify: (id: string, modifiedAction: string) => void
  testId?: string
}

export function HumanInTheLoop({
  request,
  onApprove,
  onReject,
  onModify,
  testId,
}: HumanInTheLoopProps) {
  const [remaining, setRemaining] = useState(request.timeoutSeconds)
  const [modifying, setModifying] = useState(false)
  const [modifiedAction, setModifiedAction] = useState(request.action)
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const summary = summarizeHumanInTheLoop(request, remaining)
  const risk = riskConfig(summary.riskLevel)

  useEffect(() => {
    timerRef.current = setInterval(() => {
      setRemaining((r) => {
        if (r <= 1) {
          if (timerRef.current) clearInterval(timerRef.current)
          onReject(request.id)
          return 0
        }
        return r - 1
      })
    }, 1000)
    return () => {
      if (timerRef.current) clearInterval(timerRef.current)
    }
  }, [request.id, request.timeoutSeconds, onReject])

  const handleApprove = () => {
    if (timerRef.current) clearInterval(timerRef.current)
    onApprove(request.id)
  }

  const handleReject = () => {
    if (timerRef.current) clearInterval(timerRef.current)
    onReject(request.id)
  }

  const handleApplyModify = () => {
    if (timerRef.current) clearInterval(timerRef.current)
    onModify(request.id, modifiedAction)
    setModifying(false)
  }

  const riskLabelClass = summary.isCritical
    ? 'text-[var(--color-status-err)]'
    : 'text-[var(--color-fg-secondary)]'

  return html`
    <div
      class="max-w-full rounded-[var(--r-1)] border p-3 ${risk.border} ${risk.bg}"
      role="alertdialog"
      aria-label="사람 개입 요청"
      aria-live="polite"
      data-human-in-the-loop
      data-approval-id=${summary.requestId}
      data-approval-agent-id=${summary.agentId}
      data-approval-agent-short=${summary.agentShort}
      data-approval-risk-level=${summary.riskLevel}
      data-approval-risk-label=${summary.riskLabel}
      data-approval-critical=${summary.isCritical}
      data-approval-timeout-seconds=${summary.timeoutSeconds}
      data-approval-remaining-seconds=${summary.remainingSeconds}
      data-approval-countdown=${summary.countdown}
      data-approval-expired=${summary.expired}
      data-approval-modifying=${modifying}
      data-approval-action-length=${summary.actionLength}
      data-approval-details-length=${summary.detailsLength}
      data-approval-has-details=${summary.hasDetails}
      data-testid=${testId}
    >
      <div class="mb-2 flex items-center justify-between">
        <span class="text-xs font-medium ${riskLabelClass}">
          ${summary.riskLabel} · ${summary.agentShort}
        </span>
        <span
          class="font-mono text-xs text-[var(--color-fg-secondary)]"
          aria-label="남은 시간 ${summary.countdown}"
          data-testid="${testId ? `${testId}-timer` : undefined}"
        >
          ${summary.countdown}
        </span>
      </div>

      <div class="mb-1 break-words text-sm font-medium text-[var(--color-fg-primary)]">
        ${request.action}
      </div>
      <div class="mb-3 break-words text-xs text-[var(--color-fg-secondary)]">
        ${request.details}
      </div>

      ${modifying
        ? html`
            <div class="mb-2">
              <textarea
                class="w-full rounded-[var(--r-1)] border border-[var(--color-accent-fg)] bg-[var(--color-bg-surface)] p-2 text-sm text-[var(--color-fg-primary)] outline-none"
                rows="2"
                aria-label="수정 내용"
                value=${modifiedAction}
                onInput=${(e: Event) =>
                  setModifiedAction((e.target as HTMLTextAreaElement).value)}
              />
              <button
                class="mt-1 text-xs text-[var(--color-accent-fg)] hover:underline"
                onClick=${handleApplyModify}
              >
                수정 내용 적용
              </button>
            </div>
          `
        : null}

      <div class="flex flex-wrap gap-2">
        <button
          class="min-w-[4rem] flex-1 rounded-[var(--r-1)] bg-[var(--color-status-ok)] py-1.5 text-sm text-white transition-opacity hover:opacity-90"
          onClick=${handleApprove}
        >
          승인
        </button>
        <button
          class="min-w-[4rem] flex-1 rounded-[var(--r-1)] bg-[var(--color-status-err)] py-1.5 text-sm text-white transition-opacity hover:opacity-90"
          onClick=${handleReject}
        >
          거부
        </button>
        <button
          class="min-w-[4rem] flex-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] px-3 py-1.5 text-sm text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-elevated)]"
          onClick=${() => setModifying((m) => !m)}
        >
          ${modifying ? '취소' : '수정'}
        </button>
      </div>
    </div>
  `
}
