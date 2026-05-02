// RecoveryWizard — AX molecule that guides through recovery steps.
//
// Kimi design system sec05 reference: macOS Time Machine recovery UX.
// Step list + auto-retry countdown. Each step shows status icon and
// current progress.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'

export interface RecoveryStep {
  id: string
  label: string
  status: 'pending' | 'running' | 'completed' | 'failed'
  autoRetry?: boolean
}

interface RecoveryWizardProps {
  steps: RecoveryStep[]
  currentStep: number
  onRetry: (stepId: string) => void
  onSkip: (stepId: string) => void
  testId?: string
}

const STEP_ICON: Record<RecoveryStep['status'], string> = {
  completed: '\u{2713}',
  failed: '\u{2715}',
  running: '\u{21BB}',
  pending: '\u{25CB}',
}

export function RecoveryWizard({
  steps,
  currentStep,
  onRetry,
  onSkip,
  testId,
}: RecoveryWizardProps) {
  const [countdown, setCountdown] = useState(5)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const current = steps[currentStep]

  useEffect(() => {
    if (current?.autoRetry && current?.status === 'failed' && countdown > 0) {
      timerRef.current = setTimeout(() => setCountdown((c) => c - 1), 1000)
      return () => {
        if (timerRef.current) clearTimeout(timerRef.current)
      }
    }
    if (current?.autoRetry && current?.status === 'failed' && countdown === 0) {
      onRetry(current.id)
      setCountdown(5)
    }
    return undefined
  }, [countdown, current, onRetry])

  useEffect(() => {
    setCountdown(5)
  }, [currentStep])

  const stepCount = steps.length
  const completedCount = steps.filter((s) => s.status === 'completed').length
  const progressPercent = stepCount > 0 ? (completedCount / stepCount) * 100 : 0

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      data-recovery-wizard
      data-testid=${testId}
    >
      <div class="mb-2 flex items-center justify-between">
        <h4 class="text-sm font-medium text-[var(--color-fg-primary)]">복구 마법사</h4>
        <span class="text-xs text-[var(--color-fg-secondary)]">
          ${completedCount}/${stepCount}
        </span>
      </div>

      <div
        class="mb-3 h-2 w-full rounded-full bg-[var(--white-10)]"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax=${stepCount}
        aria-valuenow=${completedCount}
        aria-label="복구 진행률"
      >
        <div
          class="h-full rounded-full bg-[var(--color-accent)] transition-all duration-500"
          style=${{ width: `${progressPercent}%` }}
        ></div>
      </div>

      <div class="space-y-2">
        ${steps.map((step, i) => {
          const isCurrent = i === currentStep
          const textClass = isCurrent
            ? 'text-[var(--color-fg-primary)]'
            : 'text-[var(--color-fg-secondary)]'
          const icon = STEP_ICON[step.status]
          return html`
            <div
              key=${step.id}
              class="flex items-center gap-2 py-1 ${textClass}"
              data-step-id=${step.id}
              data-step-status=${step.status}
            >
              <span
                class="flex h-4 w-4 items-center justify-center text-xs"
                aria-hidden="true"
              >
                ${icon}
              </span>
              <span class="flex-1 text-sm">${step.label}</span>
              ${step.status === 'running'
                ? html`<span class="animate-pulse text-xs text-[var(--color-accent)]">진행 중</span>`
                : null}
              ${step.status === 'failed'
                ? html`
                    <div class="flex items-center gap-1">
                      ${step.autoRetry && isCurrent
                        ? html`<span class="text-xs text-[var(--color-fg-secondary)]">${countdown}초 후 재시도</span>`
                        : null}
                      <button
                        class="text-xs text-[var(--color-accent)] hover:underline"
                        onClick=${() => onRetry(step.id)}
                      >
                        재시도
                      </button>
                      <button
                        class="text-xs text-[var(--color-fg-secondary)] hover:underline"
                        onClick=${() => onSkip(step.id)}
                      >
                        걸너뛰기
                      </button>
                    </div>
                  `
                : null}
            </div>
          `
        })}
      </div>
    </div>
  `
}
