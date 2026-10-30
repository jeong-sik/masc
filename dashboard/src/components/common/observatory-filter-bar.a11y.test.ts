// @vitest-environment happy-dom
//
// jest-axe coverage for ObservatoryFilterBar. Renders chips for each
// active filter with role="region" + aria-label on the wrapper. Each
// chip's clear button has aria-label. Uses setObservatoryFilter to
// drive state without mocking — store is module-scoped.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ObservatoryFilterBar } from './observatory-filter-bar'
import {
  setObservatoryFilter,
  clearObservatoryFilters,
} from '../../observatory-filter-store'

describe('ObservatoryFilterBar a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    clearObservatoryFilters()
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    clearObservatoryFilters()
  })

  it('no active filter (returns null) renders accessibly', async () => {
    render(html`<${ObservatoryFilterBar} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('keeper filter only passes axe', async () => {
    setObservatoryFilter({ keeper: 'sigma' })
    render(html`<${ObservatoryFilterBar} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('all four filters active pass axe', async () => {
    setObservatoryFilter({
      keeper: 'sigma',
      namespace: 'logs',
      operation: 'fetch',
      range: '1h',
    })
    render(html`<${ObservatoryFilterBar} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('time range filter only passes axe', async () => {
    setObservatoryFilter({ range: '24h' })
    render(html`<${ObservatoryFilterBar} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
