// @vitest-environment happy-dom
import { describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { SuggestionChip } from './suggestion-chip'

describe('SuggestionChip', () => {
  it('renders children and default leading arrow', () => {
    const container = document.createElement('div')
    render(html`<${SuggestionChip}>Re-run preflight<//>`, container)
    expect(container.textContent).toContain('Re-run preflight')
    const pre = container.querySelector('.suggestion-chip-pre')
    expect(pre).not.toBeNull()
    expect(pre?.textContent).toBe('\u2192')
  })

  it('renders custom pre', () => {
    const container = document.createElement('div')
    render(html`<${SuggestionChip} pre="\u21bb">Regenerate<//>`, container)
    const pre = container.querySelector('.suggestion-chip-pre')
    expect(pre?.textContent).toBe('\u21bb')
  })

  it('omits pre when null', () => {
    const container = document.createElement('div')
    render(html`<${SuggestionChip} pre=${null}>No arrow<//>`, container)
    expect(container.querySelector('.suggestion-chip-pre')).toBeNull()
  })

  it('calls onClick when pressed', () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(html`<${SuggestionChip} onClick=${onClick}>Open diff<//>`, container)
    const el = container.querySelector('button') as HTMLElement
    el.click()
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(html`<${SuggestionChip} class="my-suggestion">Action<//>`, container)
    const el = container.querySelector('button')
    expect(el?.classList.contains('suggestion-chip')).toBe(true)
    expect(el?.classList.contains('my-suggestion')).toBe(true)
  })
})
