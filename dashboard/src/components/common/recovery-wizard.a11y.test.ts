// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { RecoveryWizard } from './recovery-wizard'

describe('RecoveryWizard a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.useFakeTimers({ shouldAdvanceTime: true })
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    vi.useRealTimers()
  })

  const steps = [
    { id: 's1', label: 'Check network', status: 'completed' as const },
    { id: 's2', label: 'Restart services', status: 'running' as const },
    { id: 's3', label: 'Verify DB', status: 'failed' as const, autoRetry: true },
    { id: 's4', label: 'Notify ops', status: 'pending' as const },
  ]

  it('renders accessibly', async () => {
    render(
      html`<${RecoveryWizard}
          steps=${steps}
          currentStep=${2}
          onRetry=${vi.fn()}
          onSkip=${vi.fn()}
        />
      `,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role=progressbar with correct aria values', () => {
    render(
      html`<${RecoveryWizard}
          steps=${steps}
          currentStep=${2}
          onRetry=${vi.fn()}
          onSkip=${vi.fn()}
        />
      `,
      container,
    )
    const bar = container.querySelector('[role="progressbar"]')
    expect(bar).not.toBeNull()
    expect(bar?.getAttribute('aria-valuemin')).toBe('0')
    expect(bar?.getAttribute('aria-valuemax')).toBe('4')
    expect(bar?.getAttribute('aria-valuenow')).toBe('1')
    expect(bar?.getAttribute('aria-label')).toBe('복구 진행률')
  })

  it('renders step icons and labels', () => {
    render(
      html`<${RecoveryWizard}
          steps=${steps}
          currentStep=${2}
          onRetry=${vi.fn()}
          onSkip=${vi.fn()}
        />
      `,
      container,
    )
    expect(container.textContent).toContain('Check network')
    expect(container.textContent).toContain('Restart services')
    expect(container.textContent).toContain('Verify DB')
    expect(container.textContent).toContain('Notify ops')
  })

  it('shows running indicator for current running step', () => {
    render(
      html`<${RecoveryWizard}
          steps=${steps}
          currentStep=${1}
          onRetry=${vi.fn()}
          onSkip=${vi.fn()}
        />
      `,
      container,
    )
    expect(container.textContent).toContain('진행 중')
  })

  it('shows retry and skip buttons for failed step', () => {
    render(
      html`<${RecoveryWizard}
          steps=${steps}
          currentStep=${2}
          onRetry=${vi.fn()}
          onSkip=${vi.fn()}
        />
      `,
      container,
    )
    const buttons = container.querySelectorAll('button')
    const texts = Array.from(buttons).map((b) => b.textContent)
    expect(texts).toContain('재시도')
    expect(texts).toContain('걸너뛰기')
  })

  it('calls onRetry when retry button clicked', async () => {
    const onRetry = vi.fn()
    render(
      html`<${RecoveryWizard}
          steps=${steps}
          currentStep=${2}
          onRetry=${onRetry}
          onSkip=${vi.fn()}
        />
      `,
      container,
    )
    const retryBtn = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent === '재시도',
    ) as HTMLButtonElement
    retryBtn.click()
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(onRetry).toHaveBeenCalledWith('s3')
  })

  it('calls onSkip when skip button clicked', async () => {
    const onSkip = vi.fn()
    render(
      html`<${RecoveryWizard}
          steps=${steps}
          currentStep=${2}
          onRetry=${vi.fn()}
          onSkip=${onSkip}
        />
      `,
      container,
    )
    const skipBtn = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent === '걸너뛰기',
    ) as HTMLButtonElement
    skipBtn.click()
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(onSkip).toHaveBeenCalledWith('s3')
  })

  it('counts down and auto-calls onRetry for autoRetry step', async () => {
    const onRetry = vi.fn()
    await act(async () => {
      render(
        html`<${RecoveryWizard}
            steps=${steps}
            currentStep=${2}
            onRetry=${onRetry}
            onSkip=${vi.fn()}
          />
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(container.textContent).toContain('5초 후 재시도')
    for (let i = 0; i < 3; i++) {
      await act(async () => {
        vi.advanceTimersByTime(1000)
        await new Promise((r) => setTimeout(r, 0))
      })
    }
    expect(container.textContent).toContain('2초 후 재시도')
    for (let i = 0; i < 2; i++) {
      await act(async () => {
        vi.advanceTimersByTime(1000)
        await new Promise((r) => setTimeout(r, 0))
      })
    }
    expect(onRetry).toHaveBeenCalledWith('s3')
  })

  it('resets countdown when currentStep changes', async () => {
    const onRetry = vi.fn()
    await act(async () => {
      render(
        html`<${RecoveryWizard}
            steps=${steps}
            currentStep=${2}
            onRetry=${onRetry}
            onSkip=${vi.fn()}
          />
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))
    })
    for (let i = 0; i < 2; i++) {
      await act(async () => {
        vi.advanceTimersByTime(1000)
        await new Promise((r) => setTimeout(r, 0))
      })
    }
    expect(container.textContent).toContain('3초 후 재시도')

    await act(async () => {
      render(
        html`<${RecoveryWizard}
            steps=${steps}
            currentStep=${3}
            onRetry=${onRetry}
            onSkip=${vi.fn()}
          />
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(container.textContent).not.toContain('3초 후 재시도')
  })
})
