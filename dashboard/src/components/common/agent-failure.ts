// AgentFailure — AX atom that renders an error state with type-aware styling.
//
// Kimi design system sec05 reference: icons + color-coded borders for retryable,
// non-retryable, human-required and degraded failure types. The compact alert
// card lets operators instantly grasp severity and required action.
//
// Icons are text/emoji placeholders (Kimi spec uses emoji). Production code
// should swap the icon field for an SVG icon map when an icon library is
// adopted.

import { html } from 'htm/preact'

export type FailureType = 'retryable' | 'non_retryable' | 'human_required' | 'degraded'

interface FailureConfig {
  icon: string
  colorVar: string
  label: string
  action: string
}

const FAILURE_CONFIG: Record<FailureType, FailureConfig> = {
  retryable: {
    icon: '\u{21BB}',
    colorVar: 'var(--warn-10)',
    label: '재시도 가능',
    action: '자동 재시도 중...',
  },
  non_retryable: {
    icon: '\u{2715}',
    colorVar: 'var(--bad-light)',
    label: '재시도 불가',
    action: '수동 개입 필요',
  },
  human_required: {
    icon: '\u{1F464}',
    colorVar: 'var(--color-accent)',
    label: '승인 필요',
    action: 'Human-in-the-loop 대기 중',
  },
  degraded: {
    icon: '\u{26A0}',
    colorVar: 'var(--warn-10)',
    label: '성능 저하',
    action: '대체 모드 실행 중',
  },
}

/** Pure: lookup a failure type's display config. */
export function failureConfig(type: FailureType): FailureConfig {
  return FAILURE_CONFIG[type]
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

  return html`
    <div
      class="flex items-start gap-2 rounded border p-2"
      style="border-color: ${cfg.colorVar}; background-color: color-mix(in srgb, ${cfg.colorVar} 8%, transparent);"
      role="alert"
      data-agent-failure
      data-failure-type=${type}
      data-testid=${testId}
    >
      <span class="text-lg leading-none" aria-hidden="true">${cfg.icon}</span>
      <div class="min-w-0 flex-1">
        <div class="text-sm font-medium" style="color: ${cfg.colorVar};">
          ${cfg.label}
        </div>
        <div class="break-words text-xs text-[var(--color-fg-muted)]">
          ${message}
        </div>
        ${retryCount !== undefined && maxRetries !== undefined && maxRetries > 0
          ? html`
              <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
                재시도: ${retryCount}/${maxRetries}
              </div>
            `
          : null}
      </div>
      <span class="shrink-0 text-xs text-[var(--color-fg-muted)]">
        ${cfg.action}
      </span>
    </div>
  `
}
