import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { CommandBar } from './command-bar'

describe('CommandBar', () => {
  const actions = [
    { id: 'a', title: 'Alpha', handler: () => {} },
    { id: 'b', title: 'Beta', keywords: 'second', handler: () => {} },
    { id: 'c', title: 'Gamma', handler: () => {} },
  ]

  it('renders combobox role', () => {
    const container = document.createElement('div')
    render(h(CommandBar, { actions }), container)
    expect(container.querySelector('[role="combobox"]')).not.toBeNull()
  })

  it('renders placeholder', () => {
    const container = document.createElement('div')
    render(h(CommandBar, { actions, placeholder: 'Search...' }), container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.placeholder).toBe('Search...')
  })

  it('opens listbox on input', async () => {
    const container = document.createElement('div')
    render(h(CommandBar, { actions }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'A'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="listbox"]')).not.toBeNull()
  })

  it('filters options on input', async () => {
    const container = document.createElement('div')
    render(h(CommandBar, { actions }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'Bet'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const options = container.querySelectorAll('[role="option"]')
    expect(options.length).toBe(1)
    expect(options[0]?.textContent).toContain('Beta')
  })

  it('calls handler on Enter', async () => {
    const handler = vi.fn()
    const acts = [{ id: 'x', title: 'X', handler }]
    const container = document.createElement('div')
    render(h(CommandBar, { actions: acts }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'X'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Enter'
    input.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(handler).toHaveBeenCalledOnce()
  })

  it('calls onSelect on Enter', async () => {
    const onSelect = vi.fn()
    const acts = [{ id: 'x', title: 'X', handler: () => {} }]
    const container = document.createElement('div')
    render(h(CommandBar, { actions: acts, onSelect }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'X'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Enter'
    input.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ id: 'x' }))
  })

  it('navigates with ArrowDown', async () => {
    const container = document.createElement('div')
    render(h(CommandBar, { actions }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'A'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'ArrowDown'
    input.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    const options = container.querySelectorAll('[role="option"]')
    expect(options[1]?.getAttribute('aria-selected')).toBe('true')
  })

  it('closes on Escape', async () => {
    const container = document.createElement('div')
    render(h(CommandBar, { actions }), container)
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
    render(h(CommandBar, { actions, testId: 'cmd-1' }), container)
    expect(container.querySelector('[data-testid="cmd-1"]')).not.toBeNull()
  })
})
