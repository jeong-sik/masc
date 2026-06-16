import { describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Stepper } from './stepper'

describe('Stepper', () => {
  it('renders value and buttons', () => {
    const container = document.createElement('div')
    render(html`<${Stepper} value=${4} />`, container)
    expect(container.textContent).toContain('4')
    const buttons = container.querySelectorAll('button')
    expect(buttons.length).toBe(2)
  })

  it('decrements on minus click', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(html`<${Stepper} value=${4} onChange=${onChange} />`, container)
    const buttons = container.querySelectorAll('button')
    ;(buttons[0] as HTMLElement).click()
    expect(onChange).toHaveBeenCalledWith(3)
  })

  it('increments on plus click', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(html`<${Stepper} value=${4} onChange=${onChange} />`, container)
    const buttons = container.querySelectorAll('button')
    ;(buttons[1] as HTMLElement).click()
    expect(onChange).toHaveBeenCalledWith(5)
  })

  it('respects min boundary', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(html`<${Stepper} value=${0} min=${0} onChange=${onChange} />`, container)
    const buttons = container.querySelectorAll('button')
    ;(buttons[0] as HTMLElement).click()
    expect(onChange).toHaveBeenCalledWith(0)
  })

  it('respects max boundary', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(html`<${Stepper} value=${9} max=${9} onChange=${onChange} />`, container)
    const buttons = container.querySelectorAll('button')
    ;(buttons[1] as HTMLElement).click()
    expect(onChange).toHaveBeenCalledWith(9)
  })

  it('labels buttons for accessibility', () => {
    const container = document.createElement('div')
    render(html`<${Stepper} value=${4} />`, container)
    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('aria-label')).toBe('Decrease')
    expect(buttons[1]?.getAttribute('aria-label')).toBe('Increase')
  })
})
