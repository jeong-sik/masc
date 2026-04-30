import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Switch } from './switch'

describe('Switch', () => {
  it('renders label and value', () => {
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange: vi.fn(), label: 'Airplane' }), container)
    expect(container.textContent).toContain('Airplane')
  })

  it('has role="switch"', () => {
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange: vi.fn() }), container)
    expect(container.querySelector('[role="switch"]')).not.toBeNull()
  })

  it('applies aria-checked true', () => {
    const container = document.createElement('div')
    render(h(Switch, { checked: true, onChange: vi.fn() }), container)
    const el = container.querySelector('[role="switch"]')
    expect(el?.getAttribute('aria-checked')).toBe('true')
  })

  it('applies aria-checked false', () => {
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange: vi.fn() }), container)
    const el = container.querySelector('[role="switch"]')
    expect(el?.getAttribute('aria-checked')).toBe('false')
  })

  it('calls onChange when clicked', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange }), container)
    const el = container.querySelector('[role="switch"]') as HTMLElement
    el?.click()
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it('disabled prevents toggle', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange, disabled: true }), container)
    const el = container.querySelector('[role="switch"]') as HTMLElement
    el?.click()
    expect(onChange).not.toHaveBeenCalled()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange: vi.fn(), testId: 'sw-1' }), container)
    expect(container.querySelector('[data-testid="sw-1"]')).not.toBeNull()
  })

  it('activates with Space key', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange }), container)
    const el = container.querySelector('[role="switch"]') as HTMLElement
    const e = new KeyboardEvent('keydown', { key: ' ' })
    el?.dispatchEvent(e)
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it('activates with Enter key', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Switch, { checked: false, onChange }), container)
    const el = container.querySelector('[role="switch"]') as HTMLElement
    const e = new KeyboardEvent('keydown', { key: 'Enter' })
    el?.dispatchEvent(e)
    expect(onChange).toHaveBeenCalledWith(true)
  })
})
