// AgentTrust — AX organism that visualizes an agent's trust score and approval history.
//
// Kimi design system sec05 reference: Anthropic Constitutional AI-inspired
// confidence indicator. Score bar + approval/rejection/override counts.

import { html } from 'htm/preact'

export interface TrustMetrics {
  score: number
  approvals: number
  rejections: number
  overrides: number
}

interface AgentTrustProps {
  metrics: TrustMetrics
  testId?: string
}

function scoreColorClass(score: number): string {
  if (score >= 80) return 'text-[var(--ok-10)]'
  if (score >= 50) return 'text-[var(--warn-10)]'
  return 'text-[var(--error-10)]'
}

function scoreBarBg(score: number): string {
  if (score >= 80) return 'bg-[var(--ok-10)]'
  if (score >= 50) return 'bg-[var(--warn-10)]'
  return 'bg-[var(--error-10)]'
}

function scoreBarBgMuted(score: number): string {
  if (score >= 80) return 'bg-[var(--ok-3)]'
  if (score >= 50) return 'bg-[var(--warn-3)]'
  return 'bg-[var(--error-3)]'
}

export function AgentTrust({ metrics, testId }: AgentTrustProps) {
  const clampedScore = Math.max(0, Math.min(100, Math.round(metrics.score)))
  const total = metrics.approvals + metrics.rejections + metrics.overrides
  const approvalRate = total > 0 ? (metrics.approvals / total) * 100 : 0

  const scoreClass = scoreColorClass(clampedScore)
  const barClass = scoreBarBg(clampedScore)
  const barTrackClass = scoreBarBgMuted(clampedScore)

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      data-agent-trust
      data-testid=${testId}
    >
      <div class="mb-2 flex items-center justify-between">
        <span class="text-sm font-medium text-[var(--color-fg-primary)]">신뢰도 점수</span>
        <span class="text-lg font-bold ${scoreClass}" aria-label="신뢰도 ${clampedScore}점">
          ${clampedScore}
        </span>
      </div>

      <div
        class="mb-3 h-2 w-full rounded-full ${barTrackClass}"
        role="meter"
        aria-label="신뢰도 점수"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow=${clampedScore}
      >
        <div
          class="h-full rounded-full ${barClass} transition-all duration-[var(--t-xslow)]"
          style=${{ width: `${clampedScore}%` }}
        ></div>
      </div>

      <div class="mb-2 grid grid-cols-3 gap-2 text-center">
        <div class="rounded-[var(--r-1)] bg-[var(--ok-1)] p-1">
          <div class="text-lg text-[var(--ok-10)]" aria-label="승인 ${metrics.approvals}회">
            ${metrics.approvals}
          </div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">승인</div>
        </div>
        <div class="rounded-[var(--r-1)] bg-[var(--error-1)] p-1">
          <div class="text-lg text-[var(--error-10)]" aria-label="거부 ${metrics.rejections}회">
            ${metrics.rejections}
          </div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">거부</div>
        </div>
        <div class="rounded-[var(--r-1)] bg-[var(--warn-1)] p-1">
          <div class="text-lg text-[var(--warn-10)]" aria-label="수정 ${metrics.overrides}회">
            ${metrics.overrides}
          </div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">수정</div>
        </div>
      </div>

      <div class="text-3xs text-[var(--color-fg-secondary)]">
        승인률: ${approvalRate.toFixed(1)}% (${total}회 평가)
      </div>
    </div>
  `
}
