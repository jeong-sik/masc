import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Tooltip } from './tooltip'

describe('Tooltip', () => {
  it('renders trigger child', () => {
    const container = document.createElement('div')
    render(
      h(Tooltip, { content: 'Tip' }, h('button', null, 'Hover')),
      container,
    )
    expect(container.textContent).toContain('Hover')
  })

  it('shows tooltip after mouseenter delay', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const container = document.createElement('div')
    render(
      h(Tooltip, { content: 'Tip' }, h('button', null, 'Hover')),
      container,
    )
    const trigger = container.querySelector('button') as HTMLElement
    trigger?.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    vi.advanceTimersByTime(200)
    await new Promise((r) => setTimeout(r, 0))
    expect(container.textContent).toContain('Tip')
    vi.useRealTimers()
  })

  it('hides tooltip after mouseleave delay', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const container = document.createElement('div')
    render(
      h(Tooltip, { content: 'Tip' }, h('button', null, 'Hover')),
      container,
    )
    const trigger = container.querySelector('button') as HTMLElement
    trigger?.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    vi.advanceTimersByTime(200)
    trigger?.dispatchEvent(new MouseEvent('mouseleave', { bubbles: true }))
    vi.advanceTimersByTime(100)
    await new Promise((r) => setTimeout(r, 0))
    expect(container.textContent).not.toContain('Tip')
    vi.useRealTimers()
  })

  it('applies aria-describedby when visible', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const container = document.createElement('div')
    render(
      h(Tooltip, { content: 'Tip' }, h('button', null, 'Hover')),
      container,
    )
    const trigger = container.querySelector('button') as HTMLElement
    trigger?.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    vi.advanceTimersByTime(200)
    await new Promise((r) => setTimeout(r, 0))
    const describedBy = trigger?.getAttribute('aria-describedby')
    expect(describedBy).toBeTruthy()
    vi.useRealTimers()
  })

  it('applies testId to tooltip', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const container = document.createElement('div')
    render(
      h(Tooltip, { content: 'Tip', testId: 'tip-1' }, h('button', null, 'Hover')),
      container,
    )
    const trigger = container.querySelector('button') as HTMLElement
    trigger?.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    vi.advanceTimersByTime(200)
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[data-testid="tip-1"]')).not.toBeNull()
    vi.useRealTimers()
  })

  it('has role="tooltip" when visible', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const container = document.createElement('div')
    render(
      h(Tooltip, { content: 'Tip' }, h('button', null, 'Hover')),
      container,
    )
    const trigger = container.querySelector('button') as HTMLElement
    trigger?.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    vi.advanceTimersByTime(200)
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="tooltip"]')).not.toBeNull()
    vi.useRealTimers()
  })
})
