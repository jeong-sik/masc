import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Sigil, SigilChip } from './sigil-chip'

describe('Sigil', () => {
  it('renders children monogram', () => {
    const container = document.createElement('div')
    render(html`<${Sigil} slot=${3} size=${24}>IR<//>`, container)
    expect(container.textContent).toBe('IR')
  })

  it('sets slot css custom property', () => {
    const container = document.createElement('div')
    render(html`<${Sigil} slot=${5}>LU<//>`, container)
    const el = container.querySelector('.sigil') as HTMLElement
    expect(el?.style.getPropertyValue('--kc')).toBe('var(--kp5)')
  })

  it('sets size styles', () => {
    const container = document.createElement('div')
    render(html`<${Sigil} slot=${1} size=${40}>GR<//>`, container)
    const el = container.querySelector('.sigil') as HTMLElement
    expect(el?.style.width).toBe('40px')
    expect(el?.style.height).toBe('40px')
    expect(el?.style.fontSize).toBe('16px')
  })

  it('adds heartbeat class', () => {
    const container = document.createElement('div')
    render(html`<${Sigil} heartbeat=${true}>VX<//>`, container)
    const el = container.querySelector('.sigil')
    expect(el?.classList.contains('heartbeat')).toBe(true)
  })
})

describe('SigilChip', () => {
  it('renders monogram and label', () => {
    const container = document.createElement('div')
    render(html`<${SigilChip} slot=${3} mono="IR">iron-claw<//>`, container)
    expect(container.textContent).toContain('IR')
    expect(container.textContent).toContain('iron-claw')
  })

  it('applies slot color to chip', () => {
    const container = document.createElement('div')
    render(html`<${SigilChip} slot=${6} mono="LU">luna<//>`, container)
    const el = container.querySelector('.sigil-chip') as HTMLElement
    expect(el?.style.getPropertyValue('--kc')).toBe('var(--kp6)')
  })
})
