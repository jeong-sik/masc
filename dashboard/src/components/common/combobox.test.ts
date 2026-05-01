import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Combobox } from './combobox'

describe('Combobox', () => {
  const options = [
    { value: 'a', label: 'Alpha' },
    { value: 'b', label: 'Beta' },
    { value: 'c', label: 'Gamma' },
  ]

  it('renders combobox role', () => {
    const container = document.createElement('div')
    render(h(Combobox, { options }), container)
    expect(container.querySelector('[role="combobox"]')).not.toBeNull()
  })

  it('renders input with placeholder', () => {
    const container = document.createElement('div')
    render(h(Combobox, { options, placeholder: 'Pick one' }), container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.placeholder).toBe('Pick one')
  })

  it('opens listbox on input', async () => {
    const container = document.createElement('div')
    render(h(Combobox, { options }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'A'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="listbox"]')).not.toBeNull()
  })

  it('filters options', async () => {
    const container = document.createElement('div')
    render(h(Combobox, { options }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'Bet'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const opts = container.querySelectorAll('[role="option"]')
    expect(opts.length).toBe(1)
    expect(opts[0]?.textContent).toContain('Beta')
  })

  it('calls onChange on input', async () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Combobox, { options, onChange }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'A'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith('A')
  })

  it('calls onChange on option click', async () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Combobox, { options, onChange }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'Bet'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const opts = container.querySelectorAll('[role="option"]')
    expect(opts.length).toBe(1)
    ;(opts[0] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith('b')
  })

  it('navigates with ArrowDown', async () => {
    const container = document.createElement('div')
    render(h(Combobox, { options }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'A'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'ArrowDown'
    input.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    const opts = container.querySelectorAll('[role="option"]')
    expect(opts[1]?.getAttribute('aria-selected')).toBe('true')
  })

  it('closes on Escape', async () => {
    const container = document.createElement('div')
    render(h(Combobox, { options }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    await new Promise((r) => setTimeout(r, 0))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Escape'
    input.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="listbox"]')).toBeNull()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(Combobox, { options, testId: 'cb-1' }), container)
    expect(container.querySelector('[data-testid="cb-1"]')).not.toBeNull()
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Combobox, { options, 'aria-label': 'my combo' }), container)
    const input = container.querySelector('input')
    expect(input?.getAttribute('aria-label')).toBe('my combo')
  })
})
