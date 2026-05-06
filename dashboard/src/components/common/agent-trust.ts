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

export type TrustScoreBand = 'high' | 'medium' | 'low'

export interface TrustToneConfig {
  scoreClass: string
  barClass: string
  barTrackClass: string
}

export interface AgentTrustSummary {
  readonly rawScore: number
  readonly score: number
  readonly band: TrustScoreBand
  readonly approvals: number
  readonly rejections: number
  readonly overrides: number
  readonly total: number
  readonly approvalRate: number
  readonly approvalRateLabel: string
  readonly hasEvaluations: boolean
}

interface AgentTrustProps {
  metrics: TrustMetrics
  testId?: string
}

export function clampTrustScore(score: number): number {
  return Math.max(0, Math.min(100, Math.round(score)))
}

export function trustScoreBand(score: number): TrustScoreBand {
  if (score >= 80) return 'high'
  if (score >= 50) return 'medium'
  return 'low'
}

const TRUST_TONE_CONFIG: Record<TrustScoreBand, TrustToneConfig> = {
  high: {
    scoreClass: 'text-[var(--color-status-ok)]',
    barClass: 'bg-[var(--color-status-ok)]',
    barTrackClass: 'bg-[var(--color-status-ok)]/15',
  },
  medium: {
    scoreClass: 'text-[var(--color-status-warn)]',
    barClass: 'bg-[var(--color-status-warn)]',
    barTrackClass: 'bg-[var(--color-status-warn)]/15',
  },
  low: {
    scoreClass: 'text-[var(--color-status-err)]',
    barClass: 'bg-[var(--color-status-err)]',
    barTrackClass: 'bg-[var(--color-status-err)]/15',
  },
}

export function trustToneConfig(band: TrustScoreBand): TrustToneConfig {
  return TRUST_TONE_CONFIG[band]
}

export function summarizeAgentTrust(metrics: TrustMetrics): AgentTrustSummary {
  const score = clampTrustScore(metrics.score)
  const total = metrics.approvals + metrics.rejections + metrics.overrides
  const approvalRate = total > 0 ? (metrics.approvals / total) * 100 : 0

  return {
    rawScore: metrics.score,
    score,
    band: trustScoreBand(score),
    approvals: metrics.approvals,
    rejections: metrics.rejections,
    overrides: metrics.overrides,
    total,
    approvalRate,
    approvalRateLabel: approvalRate.toFixed(1),
    hasEvaluations: total > 0,
  }
}

export function AgentTrust({ metrics, testId }: AgentTrustProps) {
  const summary = summarizeAgentTrust(metrics)
  const tone = trustToneConfig(summary.band)

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      data-agent-trust
      data-trust-raw-score=${summary.rawScore}
      data-trust-score=${summary.score}
      data-trust-band=${summary.band}
      data-trust-approvals=${summary.approvals}
      data-trust-rejections=${summary.rejections}
      data-trust-overrides=${summary.overrides}
      data-trust-total=${summary.total}
      data-trust-approval-rate=${summary.approvalRateLabel}
      data-trust-has-evaluations=${summary.hasEvaluations}
      data-testid=${testId}
    >
      <div class="mb-2 flex items-center justify-between">
        <span class="text-sm font-medium text-[var(--color-fg-primary)]">신뢰도 점수</span>
        <span class="text-lg font-bold ${tone.scoreClass}" aria-label="신뢰도 ${summary.score}점">
          ${summary.score}
        </span>
      </div>

      <div
        class="mb-3 h-2 w-full rounded-full ${tone.barTrackClass}"
        role="meter"
        aria-label="신뢰도 점수"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow=${summary.score}
      >
        <div
          class="h-full rounded-full ${tone.barClass} transition-[width] duration-[var(--t-xslow)]"
          style=${{ width: `${summary.score}%` }}
        ></div>
      </div>

      <div class="mb-2 grid grid-cols-3 gap-2 text-center">
        <div class="min-w-0 rounded-[var(--r-1)] bg-[var(--color-status-ok)]/12 p-1">
          <div class="text-lg text-[var(--color-status-ok)]" aria-label="승인 ${summary.approvals}회">
            ${summary.approvals}
          </div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">승인</div>
        </div>
        <div class="min-w-0 rounded-[var(--r-1)] bg-[var(--color-status-err)]/12 p-1">
          <div class="text-lg text-[var(--color-status-err)]" aria-label="거부 ${summary.rejections}회">
            ${summary.rejections}
          </div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">거부</div>
        </div>
        <div class="min-w-0 rounded-[var(--r-1)] bg-[var(--color-status-warn)]/12 p-1">
          <div class="text-lg text-[var(--color-status-warn)]" aria-label="수정 ${summary.overrides}회">
            ${summary.overrides}
          </div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">수정</div>
        </div>
      </div>

      <div class="text-3xs text-[var(--color-fg-secondary)]">
        승인률: ${summary.approvalRateLabel}% (${summary.total}회 평가)
      </div>
    </div>
  `
}
