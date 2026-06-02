// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Chip, chipAriaLabel } from './chip'

describe('Chip', () => {
  const makeContainer = () => document.createElement('div')

  it('renders with default kind and size', () => {
    const container = makeContainer()
    render(html`<${Chip}>LABEL<//>`, container)
    const span = container.querySelector('span')
    expect(span).not.toBeNull()
    expect(span!.getAttribute('data-kind')).toBe('neutral')
    expect(span!.getAttribute('data-size')).toBe('default')
    expect(span!.textContent).toContain('LABEL')
    render(null, container)
  })

  it('renders each kind correctly', () => {
    const kinds = ['neutral', 'brass', 'ok', 'warn', 'err', 'info', 'stalled', 'ghost']
    for (const kind of kinds) {
      const container = makeContainer()
      render(html`<${Chip} kind=${kind}>${kind}<//>`, container)
      const span = container.querySelector('span')
      expect(span!.getAttribute('data-kind')).toBe(kind)
      render(null, container)
    }
  })

  it('renders each size correctly', () => {
    const sizes = ['sm', 'default', 'lg']
    for (const size of sizes) {
      const container = makeContainer()
      render(html`<${Chip} size=${size}>S<//>`, container)
      const span = container.querySelector('span')
      expect(span!.getAttribute('data-size')).toBe(size)
      render(null, container)
    }
  })

  it('shows dot for semantic kinds', () => {
    const container = makeContainer()
    render(html`<${Chip} kind="ok" dot>OK<//>`, container)
    const dot = container.querySelector('span[aria-hidden="true"]')
    expect(dot).not.toBeNull()
    render(null, container)
  })

  it('suppresses dot for neutral', () => {
    const container = makeContainer()
    render(html`<${Chip} kind="neutral" dot>N<//>`, container)
    const dot = container.querySelector('span[aria-hidden="true"]')
    expect(dot).toBeNull()
    render(null, container)
  })

  it('suppresses dot for ghost', () => {
    const container = makeContainer()
    render(html`<${Chip} kind="ghost" dot>G<//>`, container)
    const dot = container.querySelector('span[aria-hidden="true"]')
    expect(dot).toBeNull()
    render(null, container)
  })

  it('forwards testId', () => {
    const container = makeContainer()
    render(html`<${Chip} testId="my-chip">T<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('data-testid')).toBe('my-chip')
    render(null, container)
  })

  it('forwards title', () => {
    const container = makeContainer()
    render(html`<${Chip} title="tooltip">T<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('title')).toBe('tooltip')
    render(null, container)
  })

  it('adds role=status for semantic kinds', () => {
    const container = makeContainer()
    render(html`<${Chip} kind="ok">O<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('role')).toBe('status')
    render(null, container)
  })

  it('omits role for neutral', () => {
    const container = makeContainer()
    render(html`<${Chip} kind="neutral">N<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('role')).toBeNull()
    render(null, container)
  })

  it('omits role for ghost', () => {
    const container = makeContainer()
    render(html`<${Chip} kind="ghost">G<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('role')).toBeNull()
    render(null, container)
  })

  it('sets aria-label from chipAriaLabel', () => {
    const container = makeContainer()
    render(html`<${Chip} kind="ok">PASS<//>`, container)
    const span = container.querySelector('span')
    expect(span!.getAttribute('aria-label')).toBe('PASS (passing)')
    render(null, container)
  })
})

describe('chipAriaLabel', () => {
  it('returns override when ariaLabel is set', () => {
    expect(chipAriaLabel({ children: 'X', ariaLabel: 'custom' }, 'X')).toBe('custom')
  })

  it('announces ok as passing', () => {
    expect(chipAriaLabel({ children: 'OK', kind: 'ok' }, 'OK')).toBe('OK (passing)')
  })

  it('announces err as failing', () => {
    expect(chipAriaLabel({ children: 'FAIL', kind: 'err' }, 'FAIL')).toBe('FAIL (failing)')
  })

  it('returns plain content for neutral', () => {
    expect(chipAriaLabel({ children: 'N', kind: 'neutral' }, 'N')).toBe('N')
  })

  it('returns plain content for ghost', () => {
    expect(chipAriaLabel({ children: 'G', kind: 'ghost' }, 'G')).toBe('G')
  })
})
