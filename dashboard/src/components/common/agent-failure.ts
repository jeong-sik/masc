// AgentFailure — AX atom that renders an error state with type-aware styling.
//
// Kimi design system sec05 reference: icons + color-coded borders for retryable,
// non-retryable, human-required and degraded failure types. The compact alert
// card lets operators instantly grasp severity and required action.
//
import { html } from 'htm/preact'
import { AlertTriangle, RefreshCcw, UserRound, XCircle } from 'lucide-preact'
import type { LucideIcon } from 'lucide-preact'

export type FailureType = 'retryable' | 'non_retryable' | 'human_required' | 'degraded'
export type AgentFailureStatus = 'retrying' | 'retry_exhausted' | 'blocked' | 'waiting_for_human' | 'degraded'

export interface FailureConfig {
  Icon: LucideIcon
  colorVar: string
  label: string
  action: string
}

export interface AgentFailureRetryBudget {
  readonly current: number
  readonly max: number
  readonly remaining: number
  readonly percent: number
  readonly exhausted: boolean
  readonly visible: boolean
}

export interface AgentFailureSummary {
  readonly type: FailureType
  readonly label: string
  readonly action: string
  readonly status: AgentFailureStatus
  readonly retry: AgentFailureRetryBudget
}

const FAILURE_CONFIG: Record<FailureType, FailureConfig> = {
  retryable: {
    Icon: RefreshCcw,
    colorVar: 'var(--color-status-warn)',
    label: '재시도 가능',
    action: '자동 재시도 중...',
  },
  non_retryable: {
    Icon: XCircle,
    colorVar: 'var(--color-status-err)',
    label: '재시도 불가',
    action: '수동 개입 필요',
  },
  human_required: {
    Icon: UserRound,
    colorVar: 'var(--color-accent-fg)',
    label: '승인 필요',
    action: 'Human-in-the-loop 대기 중',
  },
  degraded: {
    Icon: AlertTriangle,
    colorVar: 'var(--color-status-warn)',
    label: '성능 저하',
    action: '대체 모드 실행 중',
  },
}

/** Pure: lookup a failure type's display config. */
export function failureConfig(type: FailureType): FailureConfig {
  return FAILURE_CONFIG[type]
}

export function summarizeRetryBudget(
  retryCount: number | undefined,
  maxRetries: number | undefined,
): AgentFailureRetryBudget {
  const finiteRetryCount =
    typeof retryCount === 'number' && Number.isFinite(retryCount) ? retryCount : undefined
  const finiteMaxRetries =
    typeof maxRetries === 'number' && Number.isFinite(maxRetries) ? maxRetries : undefined
  if (finiteRetryCount === undefined || finiteMaxRetries === undefined || finiteMaxRetries <= 0) {
    return {
      current: 0,
      max: 0,
      remaining: 0,
      percent: 0,
      exhausted: false,
      visible: false,
    }
  }
  const current = Math.max(0, Math.floor(finiteRetryCount))
  const max = Math.max(1, Math.floor(finiteMaxRetries))
  const clampedCurrent = max > 0 ? Math.min(current, max) : 0
  return {
    current,
    max,
    remaining: Math.max(0, max - clampedCurrent),
    percent: max > 0 ? Math.round((clampedCurrent / max) * 100) : 0,
    exhausted: max > 0 && current >= max,
    visible: true,
  }
}

export function summarizeAgentFailure(
  type: FailureType,
  retryCount?: number,
  maxRetries?: number,
): AgentFailureSummary {
  const cfg = failureConfig(type)
  const retry = summarizeRetryBudget(retryCount, maxRetries)
  const status: AgentFailureStatus =
    type === 'retryable'
      ? retry.exhausted
        ? 'retry_exhausted'
        : 'retrying'
      : type === 'human_required'
        ? 'waiting_for_human'
        : type === 'degraded'
          ? 'degraded'
          : 'blocked'
  return {
    type,
    label: cfg.label,
    action: cfg.action,
    status,
    retry,
  }
}

/** Pure: map a diagnostic error + recoverable flag to a failure type.
    Defaults to degraded when no error is present, and non_retryable
    when recoverable is false or undefined. */
export function failureTypeFromDiagnostic(
  lastError: string | null | undefined,
  recoverable: boolean | undefined,
): FailureType {
  if (!lastError) return 'degraded'
  if (recoverable === true) return 'retryable'
  return 'non_retryable'
}

interface AgentFailureProps {
  type: FailureType
  message: string
  retryCount?: number
  maxRetries?: number
  testId?: string
}

export function AgentFailure({
  type,
  message,
  retryCount,
  maxRetries,
  testId,
}: AgentFailureProps) {
  const cfg = FAILURE_CONFIG[type]
  const summary = summarizeAgentFailure(type, retryCount, maxRetries)
  const Icon = cfg.Icon

  return html`
    <div
      class="grid grid-cols-[auto_minmax(0,1fr)] gap-2 rounded-[var(--r-1)] border p-2 sm:grid-cols-[auto_minmax(0,1fr)_auto]"
      style="border-color: ${cfg.colorVar}; background-color: color-mix(in srgb, ${cfg.colorVar} 8%, transparent);"
      role="alert"
      aria-label="${summary.label}: ${message || '상세 메시지 없음'}"
      data-agent-failure
      data-failure-type=${type}
      data-agent-failure-status=${summary.status}
      data-agent-failure-label=${summary.label}
      data-agent-failure-action=${summary.action}
      data-agent-failure-retry-current=${summary.retry.current}
      data-agent-failure-retry-max=${summary.retry.max}
      data-agent-failure-retry-remaining=${summary.retry.remaining}
      data-agent-failure-retry-percent=${summary.retry.percent}
      data-agent-failure-retry-exhausted=${summary.retry.exhausted}
      data-agent-failure-retry-visible=${summary.retry.visible}
      data-testid=${testId}
    >
      <span class="mt-0.5 shrink-0 leading-none" style="color: ${cfg.colorVar};" aria-hidden="true">
        <${Icon} size=${16} strokeWidth=${2} />
      </span>
      <div class="min-w-0 flex-1">
        <div class="text-sm font-medium" style="color: ${cfg.colorVar};">
          ${cfg.label}
        </div>
        <div class="break-words text-xs text-[var(--color-fg-muted)]">
          ${message}
        </div>
        ${summary.retry.visible
          ? html`
              <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
                재시도: ${summary.retry.current}/${summary.retry.max}
              </div>
            `
          : null}
      </div>
      <span class="col-start-2 text-xs text-[var(--color-fg-muted)] sm:col-start-auto sm:shrink-0 sm:text-right">
        ${cfg.action}
      </span>
    </div>
  `
}
