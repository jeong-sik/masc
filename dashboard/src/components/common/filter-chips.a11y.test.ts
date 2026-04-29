// @vitest-environment happy-dom
//
// jest-axe coverage for FilterChips. role="tablist" wrapper + role="tab"
// children + aria-selected on the active chip — this is the WAI-ARIA
// tabs pattern. Tests pin uncontrolled (value+onChange) and signal
// (active=Signal<T>) APIs both axe-clean across both tones and sizes.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { signal } from '@preact/signals'
import { FilterChips } from './filter-chips'

describe('FilterChips a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const chips = [
    { key: 'all', label: 'All' },
    { key: 'active', label: 'Active', count: 12 },
    { key: 'idle', label: 'Idle', count: 3 },
  ] as const

  it('value + onChange (uncontrolled-ish) passes axe', async () => {
    render(
      html`<${FilterChips}
        chips=${chips}
        value="active"
        onChange=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('signal-driven (active=Signal<T>) passes axe', async () => {
    const active = signal<'all' | 'active' | 'idle'>('all')
    render(
      html`<${FilterChips} chips=${chips} active=${active} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('size=md + tone=accent passes axe', async () => {
    render(
      html`<${FilterChips}
        chips=${chips}
        value="idle"
        onChange=${() => {}}
        size="md"
        tone="accent"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('chip with title attribute passes axe', async () => {
    const chipsWithTitle = [
      { key: 'all', label: 'All', title: 'Show every keeper' },
      { key: 'live', label: 'Live', title: 'Currently active only' },
    ] as const
    render(
      html`<${FilterChips}
        chips=${chipsWithTitle}
        value="live"
        onChange=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
