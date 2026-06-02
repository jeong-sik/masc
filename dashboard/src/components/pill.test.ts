// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Pill, pillAriaLabel } from './pill'

describe('Pill', () => {
  const makeContainer = () => document.createElement('div')

  it('renders with default kind', () => {
    const container = makeContainer()
    render(html`<${Pill}>LABEL<//>`, container)
    const span = container.querySelector('span')
    expect(span).not.toBeNull()
    expect(span!.getAttribute('data-kind')).toBe('neutral')
    expect(span!.textContent).toContain('LABEL')
    render(null, container)
  })

  it('renders each kind correctly', () => {
    const kinds = ['neutral', 'running', 'paused', 'ok', 'warn', 'err', 'info', 'stalled']
    for (const kind of kinds) {
      const container = makeContainer()
      render(html`<${Pill} kind=${kind}>${kind}<//>`, container)
      const span = container.querySelector('span')
      expect(span!.getAttribute('data-kind')).toBe(kind)
      render(null, container)
    }
  })

  it('shows dot for semantic kinds', () => {
    const container = makeContainer()
    render(html`<${Pill} kind="running" dot>RUN<//>`, container)
    const dot = container.querySelector('span[aria-hidden="true"]')
    expect(dot).not.toBeNull()
    render(null, container)
  })

  it('suppresses dot for neutral', () => {
    const container = makeContainer()
    render(html`<${Pill} kind="neutral" dot>N<//>`, container)
    const dot = container.querySelector('span[aria-hidden="true"]')
    expect(dot).toBeNull()
    render(null, container)
  })

  it('forwards testId', () => {
    const container = makeContainer()
    render(html`<${Pill} testId="my-pill">T<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('data-testid')).toBe('my-pill')
    render(null, container)
  })

  it('forwards title', () => {
    const container = makeContainer()
    render(html`<${Pill} title="tooltip">T<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('title')).toBe('tooltip')
    render(null, container)
  })

  it('adds role=status for semantic kinds', () => {
    const container = makeContainer()
    render(html`<${Pill} kind="running">R<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('role')).toBe('status')
    render(null, container)
  })

  it('omits role for neutral', () => {
    const container = makeContainer()
    render(html`<${Pill} kind="neutral">N<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('role')).toBeNull()
    render(null, container)
  })

  it('sets aria-label from pillAriaLabel', () => {
    const container = makeContainer()
    render(html`<${Pill} kind="err">FAIL<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('aria-label')).toBe('FAIL (failing)')
    render(null, container)
  })
})

describe('pillAriaLabel', () => {
  it('returns override when ariaLabel is set', () => {
    expect(pillAriaLabel({ children: 'X', ariaLabel: 'custom' }, 'X')).toBe('custom')
  })

  it('announces running', () => {
    expect(pillAriaLabel({ children: 'R', kind: 'running' }, 'R')).toBe('R (running)')
  })

  it('announces err as failing', () => {
    expect(pillAriaLabel({ children: 'E', kind: 'err' }, 'E')).toBe('E (failing)')
  })

  it('returns plain content for neutral', () => {
    expect(pillAriaLabel({ children: 'N', kind: 'neutral' }, 'N')).toBe('N')
  })
})
