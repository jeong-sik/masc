// AgentFailure — AX atom that renders an observed failure state.
//
// The dashboard displays typed operator state only. It does not infer a replay
// policy from a generic `recoverable` boolean or maintain a local attempt budget.
import { html } from 'htm/preact'
import { AlertTriangle, UserRound, XCircle } from 'lucide-preact'
import type { LucideIcon } from 'lucide-preact'

export type FailureType = 'blocked' | 'human_required' | 'degraded'
export type AgentFailureStatus = 'blocked' | 'waiting_for_human' | 'degraded'

export interface FailureConfig {
  Icon: LucideIcon
  colorVar: string
  label: string
  action: string
}

export interface AgentFailureSummary {
  readonly type: FailureType
  readonly label: string
  readonly action: string
  readonly status: AgentFailureStatus
}

const FAILURE_CONFIG: Record<FailureType, FailureConfig> = {
  blocked: {
    Icon: XCircle,
    colorVar: 'var(--color-status-err)',
    label: '진행 차단',
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

export function failureConfig(type: FailureType): FailureConfig {
  return FAILURE_CONFIG[type]
}

export function summarizeAgentFailure(type: FailureType): AgentFailureSummary {
  const cfg = failureConfig(type)
  const status: AgentFailureStatus = type === 'human_required'
    ? 'waiting_for_human'
    : type
  return { type, label: cfg.label, action: cfg.action, status }
}

export function failureTypeFromDiagnostic(
  lastError: string | null | undefined,
): FailureType {
  return lastError ? 'blocked' : 'degraded'
}

interface AgentFailureProps {
  type: FailureType
  message: string
  testId?: string
}

export function AgentFailure({ type, message, testId }: AgentFailureProps) {
  const cfg = FAILURE_CONFIG[type]
  const summary = summarizeAgentFailure(type)
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
      </div>
      <span class="col-start-2 text-xs text-[var(--color-fg-muted)] sm:col-start-auto sm:shrink-0 sm:text-right">
        ${cfg.action}
      </span>
    </div>
  `
}
