// @vitest-environment happy-dom
//
// jest-axe coverage for AsyncContainer. Switches between LoadingState /
// ErrorState / EmptyState / render(data) based on signal-driven
// AsyncState. All 4 branches must axe-clean — the underlying
// LoadingState/ErrorState/EmptyState already do (batch 5), but the
// container's switch must not introduce wrapper-level violations.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { signal } from '@preact/signals'
import { AsyncContainer } from './async-container'
import type { AsyncState } from '../../lib/async-state'

interface SampleData { items: string[] }

describe('AsyncContainer a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('idle status passes axe', async () => {
    const state = signal<AsyncState<SampleData>>({ status: 'idle' })
    render(
      html`<${AsyncContainer}
        state=${state}
        render=${(d: SampleData) => html`<div>${d.items.length}</div>`}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('loading status passes axe', async () => {
    const state = signal<AsyncState<SampleData>>({ status: 'loading' })
    render(
      html`<${AsyncContainer}
        state=${state}
        render=${(d: SampleData) => html`<div>${d.items.length}</div>`}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('error status passes axe', async () => {
    const state = signal<AsyncState<SampleData>>({ status: 'error', message: 'Connection refused' })
    render(
      html`<${AsyncContainer}
        state=${state}
        render=${(d: SampleData) => html`<div>${d.items.length}</div>`}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('loaded + empty branch passes axe', async () => {
    const state = signal<AsyncState<SampleData>>({
      status: 'loaded',
      data: { items: [] },
    })
    render(
      html`<${AsyncContainer}
        state=${state}
        render=${(d: SampleData) => html`<ul>${d.items.map(x => html`<li>${x}</li>`)}</ul>`}
        emptyWhen=${(d: SampleData) => d.items.length === 0}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('loaded + render branch passes axe', async () => {
    const state = signal<AsyncState<SampleData>>({
      status: 'loaded',
      data: { items: ['alpha', 'beta'] },
    })
    render(
      html`<${AsyncContainer}
        state=${state}
        render=${(d: SampleData) => html`<ul>${d.items.map(x => html`<li>${x}</li>`)}</ul>`}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
