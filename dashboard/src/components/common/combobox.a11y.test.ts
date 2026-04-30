// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Combobox } from './combobox'

const OPTIONS = [
  { value: 'apple', label: 'Apple' },
  { value: 'banana', label: 'Banana' },
  { value: 'cherry', label: 'Cherry' },
]

describe('Combobox a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(
      html`<${Combobox}
        options=${OPTIONS}
        value=""
        placeholder="Search"
        aria-label="Fruit"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role combobox', () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]')
    expect(input).not.toBeNull()
  })

  it('aria-expanded is false initially', () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    expect(input.getAttribute('aria-expanded')).toBe('false')
  })

  it('opens listbox on ArrowDown', async () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(input.getAttribute('aria-expanded')).toBe('true')
    expect(container.querySelector('[role="listbox"]')).not.toBeNull()
  })

  it('sets aria-activedescendant on navigate', async () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    const ad = input.getAttribute('aria-activedescendant')
    expect(ad).toBeTruthy()
    expect(container.querySelector(`#${ad}`)).not.toBeNull()
  })

  it('options have role option', async () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    const options = container.querySelectorAll('[role="option"]')
    expect(options.length).toBe(OPTIONS.length)
  })

  it('selects option on Enter', async () => {
    const onChange = vi.fn()
    render(
      html`<${Combobox}
        options=${OPTIONS}
        aria-label="Fruit"
        onChange=${onChange}
      />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith('apple')
  })

  it('closes on Escape', async () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="listbox"]')).not.toBeNull()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 50))
    expect(container.querySelector('[role="listbox"]')).toBeNull()
  })

  it('filters options on type', async () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.value = 'ap'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const options = container.querySelectorAll('[role="option"]')
    expect(options.length).toBe(1)
    expect(options[0]!.textContent).toBe('Apple')
  })

  it('calls onChange with typed value', async () => {
    const onChange = vi.fn()
    render(
      html`<${Combobox}
        options=${OPTIONS}
        aria-label="Fruit"
        onChange=${onChange}
      />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.value = 'ban'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith('ban')
  })

  it('sets aria-label on listbox', async () => {
    render(
      html`<${Combobox} options=${OPTIONS} aria-label="Fruit" />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    const listbox = container.querySelector('[role="listbox"]')
    expect(listbox?.getAttribute('aria-label')).toBe('Fruit options')
  })

  it('click selects option', async () => {
    const onChange = vi.fn()
    render(
      html`<${Combobox}
        options=${OPTIONS}
        aria-label="Fruit"
        onChange=${onChange}
      />`,
      container,
    )
    const input = container.querySelector('[role="combobox"]') as HTMLInputElement
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    const option = container.querySelectorAll('[role="option"]')[1] as HTMLElement
    option.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith('banana')
  })
})
