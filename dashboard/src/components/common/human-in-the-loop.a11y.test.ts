// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { HumanInTheLoop } from './human-in-the-loop'

describe('HumanInTheLoop a11y', () => {
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

  const baseRequest = {
    id: 'req-1',
    agentId: 'agent-abc-123',
    action: 'Delete production database',
    details: 'This will drop the main PostgreSQL cluster.',
    riskLevel: 'critical' as const,
    timeoutSeconds: 300,
    requestedAt: Date.now(),
  }

  it('renders accessibly', async () => {
    render(
      html`<${HumanInTheLoop}
          request=${baseRequest}
          onApprove=${vi.fn()}
          onReject=${vi.fn()}
          onModify=${vi.fn()}
        />
      `,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role=alertdialog', () => {
    render(
      html`<${HumanInTheLoop}
          request=${baseRequest}
          onApprove=${vi.fn()}
          onReject=${vi.fn()}
          onModify=${vi.fn()}
        />
      `,
      container,
    )
    const dialog = container.querySelector('[role="alertdialog"]')
    expect(dialog).not.toBeNull()
  })

  it('renders risk-specific styling for each level', () => {
    const levels = ['low', 'medium', 'high', 'critical'] as const
    for (const level of levels) {
      render(
        html`<${HumanInTheLoop}
            request=${{ ...baseRequest, riskLevel: level }}
            onApprove=${vi.fn()}
            onReject=${vi.fn()}
            onModify=${vi.fn()}
          />
        `,
        container,
      )
      const dialog = container.querySelector('[role="alertdialog"]')
      expect(dialog).not.toBeNull()
      render(null, container)
    }
  })

  it('displays countdown timer', () => {
    render(
      html`<${HumanInTheLoop}
          request=${{ ...baseRequest, timeoutSeconds: 125 }}
          onApprove=${vi.fn()}
          onReject=${vi.fn()}
          onModify=${vi.fn()}
        />
      `,
      container,
    )
    expect(container.textContent).toContain('2:05')
  })

  it('has approve, reject and modify buttons', () => {
    render(
      html`<${HumanInTheLoop}
          request=${baseRequest}
          onApprove=${vi.fn()}
          onReject=${vi.fn()}
          onModify=${vi.fn()}
        />
      `,
      container,
    )
    const buttons = container.querySelectorAll('button')
    const texts = Array.from(buttons).map((b) => b.textContent)
    expect(texts).toContain('승인')
    expect(texts).toContain('거부')
    expect(texts).toContain('수정')
  })

  it('switches to modify mode on modify click', async () => {
    render(
      html`<${HumanInTheLoop}
          request=${baseRequest}
          onApprove=${vi.fn()}
          onReject=${vi.fn()}
          onModify=${vi.fn()}
        />
      `,
      container,
    )
    const modifyBtn = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent === '수정',
    ) as HTMLButtonElement
    modifyBtn.click()
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    const textarea = container.querySelector('textarea')
    expect(textarea).not.toBeNull()
    expect(await axe(container)).toHaveNoViolations()
  })

  it('calls onApprove when approve clicked', async () => {
    const onApprove = vi.fn()
    render(
      html`<${HumanInTheLoop}
          request=${baseRequest}
          onApprove=${onApprove}
          onReject=${vi.fn()}
          onModify=${vi.fn()}
        />
      `,
      container,
    )
    const btn = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent === '승인',
    ) as HTMLButtonElement
    btn.click()
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(onApprove).toHaveBeenCalledWith('req-1')
  })

  it('calls onReject after timeout expires', async () => {
    const onReject = vi.fn()
    await act(async () => {
      render(
        html`<${HumanInTheLoop}
            request=${{ ...baseRequest, timeoutSeconds: 2 }}
            onApprove=${vi.fn()}
            onReject=${onReject}
            onModify=${vi.fn()}
          />
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))
    })
    await act(async () => {
      vi.advanceTimersByTime(1000)
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(container.textContent).toContain('0:01')
    await act(async () => {
      vi.advanceTimersByTime(1000)
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(onReject).toHaveBeenCalledWith('req-1')
  })
})
