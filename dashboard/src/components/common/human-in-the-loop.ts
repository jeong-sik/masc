// HumanInTheLoop — AX molecule for agent approval requests.
//
// Kimi design system sec05 reference: Google AI Human-in-the-loop pattern.
// Risk-level styling + countdown timer + approve/reject/modify actions.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'

export interface ApprovalRequest {
  id: string
  agentId: string
  action: string
  details: string
  riskLevel: 'low' | 'medium' | 'high' | 'critical'
  timeoutSeconds: number
  requestedAt: number
}

interface RiskConfig {
  border: string
  bg: string
  label: string
}

const RISK_CONFIG: Record<ApprovalRequest['riskLevel'], RiskConfig> = {
  low: {
    border: 'border-[var(--ok-10)]',
    bg: 'bg-[var(--ok-1)]',
    label: '낮은 위험',
  },
  medium: {
    border: 'border-[var(--warn-10)]',
    bg: 'bg-[var(--warn-1)]',
    label: '중간 위험',
  },
  high: {
    border: 'border-[var(--error-10)]',
    bg: 'bg-[var(--error-1)]',
    label: '높은 위험',
  },
  critical: {
    border: 'border-[var(--error-10)]',
    bg: 'bg-[var(--error-3)]',
    label: '심각한 위험',
  },
}

function formatCountdown(totalSeconds: number): string {
  const m = Math.floor(totalSeconds / 60)
  const s = totalSeconds % 60
  return `${m}:${s.toString().padStart(2, '0')}`
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

  const risk = RISK_CONFIG[request.riskLevel]

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

  const agentShort = request.agentId.slice(0, 8)
  const isCritical = request.riskLevel === 'critical'
  const riskLabelClass = isCritical
    ? 'text-[var(--error-10)]'
    : 'text-[var(--color-fg-secondary)]'

  return html`
    <div
      class="rounded-[var(--r-1)] border p-3 ${risk.border} ${risk.bg}"
      role="alertdialog"
      aria-label="사람 개입 요청"
      aria-live="polite"
      data-human-in-the-loop
      data-testid=${testId}
    >
      <div class="mb-2 flex items-center justify-between">
        <span class="text-xs font-medium ${riskLabelClass}">
          ${risk.label} · ${agentShort}
        </span>
        <span
          class="font-mono text-xs text-[var(--color-fg-secondary)]"
          aria-label="남은 시간 ${formatCountdown(remaining)}"
          data-testid="${testId ? `${testId}-timer` : undefined}"
        >
          ${formatCountdown(remaining)}
        </span>
      </div>

      <div class="mb-1 text-sm font-medium text-[var(--color-fg-primary)]">
        ${request.action}
      </div>
      <div class="mb-3 text-xs text-[var(--color-fg-secondary)]">
        ${request.details}
      </div>

      ${modifying
        ? html`
            <div class="mb-2">
              <textarea
                class="w-full rounded-[var(--r-1)] border border-[var(--color-accent)] bg-[var(--color-bg-surface)] p-2 text-sm text-[var(--color-fg-primary)] outline-none"
                rows="2"
                aria-label="수정 내용"
                value=${modifiedAction}
                onInput=${(e: Event) =>
                  setModifiedAction((e.target as HTMLTextAreaElement).value)}
              />
              <button
                class="mt-1 text-xs text-[var(--color-accent)] hover:underline"
                onClick=${handleApplyModify}
              >
                수정 내용 적용
              </button>
            </div>
          `
        : null}

      <div class="flex gap-2">
        <button
          class="flex-1 rounded-[var(--r-1)] bg-[var(--ok-10)] py-1.5 text-sm text-white transition-opacity hover:opacity-90"
          onClick=${handleApprove}
        >
          승인
        </button>
        <button
          class="flex-1 rounded-[var(--r-1)] bg-[var(--error-10)] py-1.5 text-sm text-white transition-opacity hover:opacity-90"
          onClick=${handleReject}
        >
          거부
        </button>
        <button
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-3 py-1.5 text-sm text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-elevated)]"
          onClick=${() => setModifying((m) => !m)}
        >
          ${modifying ? '취소' : '수정'}
        </button>
      </div>
    </div>
  `
}
