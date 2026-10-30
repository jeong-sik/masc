import { describe, expect, it } from 'vitest'
import { h, type ComponentChildren } from 'preact'
import { render } from 'preact'
import {
  Eyebrow,
  type EyebrowProps,
  eyebrowClasses,
  summarizeEyebrow,
} from './eyebrow'

function renderEyebrow(props: EyebrowProps = {}, children: ComponentChildren = 'Runtime') {
  const container = document.createElement('div')
  render(h(Eyebrow, props, children), container)
  return container
}

describe('Eyebrow', () => {
  it('renders children with the muted tone by default', () => {
    const container = renderEyebrow({}, 'Runtime')
    const eyebrow = container.querySelector('[data-eyebrow]')

    expect(container.textContent).toContain('Runtime')
    expect(eyebrow?.classList.contains('text-[var(--color-fg-muted)]')).toBe(true)
  })

  it('applies disabled tone classes', () => {
    const container = renderEyebrow({ tone: 'disabled' })
    const eyebrow = container.querySelector('[data-eyebrow]')

    expect(eyebrow?.classList.contains('text-[var(--color-fg-disabled)]')).toBe(true)
  })

  it('applies custom classes', () => {
    const container = renderEyebrow({ class: 'inline-block' })
    const eyebrow = container.querySelector('[data-eyebrow]')

    expect(eyebrow?.classList.contains('inline-block')).toBe(true)
  })

  it('exposes eyebrow summary metadata', () => {
    const container = renderEyebrow({ tone: 'disabled', class: 'mb-1' })
    const eyebrow = container.querySelector('[data-eyebrow]')

    expect(eyebrow?.getAttribute('data-eyebrow-tone')).toBe('disabled')
    expect(eyebrow?.getAttribute('data-eyebrow-has-custom-class')).toBe('true')
    expect(eyebrow?.getAttribute('data-eyebrow-class-length')).toBe('4')
  })

  it('summarizes default eyebrow state', () => {
    expect(summarizeEyebrow({})).toEqual({
      tone: 'muted',
      hasCustomClass: false,
      classNameLength: 0,
    })
  })

  it('summarizes custom eyebrow state', () => {
    expect(summarizeEyebrow({ tone: 'disabled', className: 'mb-1' })).toEqual({
      tone: 'disabled',
      hasCustomClass: true,
      classNameLength: 4,
    })
  })

  it('exports stable class helper output', () => {
    expect(eyebrowClasses()).toBe(
      'text-3xs uppercase tracking-wider text-[var(--color-fg-muted)]',
    )
    expect(eyebrowClasses('disabled', 'mb-1')).toBe(
      'text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1',
    )
  })
})
