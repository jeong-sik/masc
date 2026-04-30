import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { RecoveryWizard } from './recovery-wizard'

describe('RecoveryWizard', () => {
  const baseSteps = [
    { id: 's1', label: 'Step 1', status: 'completed' as const },
    { id: 's2', label: 'Step 2', status: 'running' as const },
    { id: 's3', label: 'Step 3', status: 'pending' as const },
  ]

  it('renders all steps', () => {
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps: baseSteps, currentStep: 1, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    expect(container.textContent).toContain('Step 1')
    expect(container.textContent).toContain('Step 2')
    expect(container.textContent).toContain('Step 3')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(
      h(RecoveryWizard, {
        steps: baseSteps,
        currentStep: 0,
        onRetry: vi.fn(),
        onSkip: vi.fn(),
        testId: 'recovery-1',
      }),
      container,
    )
    expect(container.querySelector('[data-testid="recovery-1"]')).not.toBeNull()
  })

  it('shows progress bar with aria attributes', () => {
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps: baseSteps, currentStep: 1, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    const bar = container.querySelector('[role="progressbar"]')
    expect(bar).not.toBeNull()
    expect(bar?.getAttribute('aria-valuemin')).toBe('0')
    expect(bar?.getAttribute('aria-valuemax')).toBe('3')
    expect(bar?.getAttribute('aria-valuenow')).toBe('1')
    expect(bar?.getAttribute('aria-label')).toBe('복구 진행률')
  })

  it('shows step count in header', () => {
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps: baseSteps, currentStep: 1, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    expect(container.textContent).toContain('1/3')
  })

  it('shows running label for running step', () => {
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps: baseSteps, currentStep: 1, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    expect(container.textContent).toContain('진행 중')
  })

  it('shows retry and skip buttons for failed step', () => {
    const steps = [{ id: 's1', label: 'S1', status: 'failed' as const }]
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps, currentStep: 0, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    expect(container.textContent).toContain('재시도')
    expect(container.textContent).toContain('걸너뛰기')
  })

  it('calls onRetry when retry clicked', () => {
    const onRetry = vi.fn()
    const steps = [{ id: 's1', label: 'S1', status: 'failed' as const }]
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps, currentStep: 0, onRetry, onSkip: vi.fn() }), container)
    const retryBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('재시도'),
    )
    retryBtn?.click()
    expect(onRetry).toHaveBeenCalledWith('s1')
  })

  it('calls onSkip when skip clicked', () => {
    const onSkip = vi.fn()
    const steps = [{ id: 's1', label: 'S1', status: 'failed' as const }]
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps, currentStep: 0, onRetry: vi.fn(), onSkip }), container)
    const skipBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('걸너뛰기'),
    )
    skipBtn?.click()
    expect(onSkip).toHaveBeenCalledWith('s1')
  })

  it('shows autoRetry countdown for current failed step', async () => {
    const steps = [{ id: 's1', label: 'S1', status: 'failed' as const, autoRetry: true }]
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps, currentStep: 0, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    expect(container.textContent).toContain('5초 후 재시도')
  })

  it('renders step icons', () => {
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps: baseSteps, currentStep: 1, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    expect(container.textContent).toContain('✓')
    expect(container.textContent).toContain('↻')
    expect(container.textContent).toContain('○')
  })

  it('sets data-step-id and data-step-status', () => {
    const container = document.createElement('div')
    render(h(RecoveryWizard, { steps: baseSteps, currentStep: 1, onRetry: vi.fn(), onSkip: vi.fn() }), container)
    const stepEl = container.querySelector('[data-step-id="s1"]')
    expect(stepEl?.getAttribute('data-step-status')).toBe('completed')
  })
})
