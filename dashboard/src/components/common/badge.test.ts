import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  CountBadge,
  countBadgeClasses,
  summarizeCountBadge,
  type CountBadgeProps,
} from './badge'

function renderCountBadge(props: Partial<CountBadgeProps> | null, value: string) {
  const container = document.createElement('div')
  render(h(CountBadge, props, value), container)
  return container
}

describe('countBadgeClasses (pure)', () => {
  it('combines base, tone, and custom classes without trailing whitespace', () => {
    const cls = countBadgeClasses('warn', 'ml-2')
    expect(cls).toContain('inline-flex')
    expect(cls).toContain('bg-[var(--warn-12)]')
    expect(cls).toContain('text-[var(--color-status-warn)]')
    expect(cls).toContain('ml-2')
    expect(countBadgeClasses('default')).not.toMatch(/\s$/)
  })
})

describe('summarizeCountBadge (pure)', () => {
  it('summarizes the default badge metadata without reading the DOM', () => {
    expect(summarizeCountBadge({})).toEqual({
      tone: 'default',
      hasCustomClass: false,
      customClassLength: 0,
    })
  })

  it('summarizes custom class metadata from CountBadgeProps', () => {
    const className = 'ml-2 ring-1'
    expect(summarizeCountBadge({ tone: 'accent', class: className })).toEqual({
      tone: 'accent',
      hasCustomClass: true,
      customClassLength: className.length,
    })
  })

  it('keeps className as a fallback alias but lets class win', () => {
    expect(summarizeCountBadge({ className: 'ml-2' }).customClassLength).toBe(4)
    expect(summarizeCountBadge({ class: 'ring-1', className: 'ml-2' }).customClassLength).toBe(6)
  })
})

describe('CountBadge', () => {
  it('renders children', () => {
    const container = renderCountBadge(null, '42')
    expect(container.textContent).toBe('42')
  })

  it('applies default tone classes', () => {
    const container = renderCountBadge(null, '1')
    const el = container.querySelector('[data-count-badge]')
    expect(el).not.toBeNull()
    expect(el?.classList.contains('bg-[var(--color-bg-hover)]')).toBe(true)
    expect(el?.classList.contains('text-[var(--color-fg-muted)]')).toBe(true)
    expect(el?.getAttribute('data-count-badge-tone')).toBe('default')
    expect(el?.getAttribute('data-count-badge-has-custom-class')).toBe('false')
    expect(el?.getAttribute('data-count-badge-custom-class-length')).toBe('0')
  })

  it('applies warn tone', () => {
    const container = renderCountBadge({ tone: 'warn' }, '!')
    const el = container.querySelector('[data-count-badge]')
    expect(el?.classList.contains('bg-[var(--warn-12)]')).toBe(true)
    expect(el?.classList.contains('text-[var(--color-status-warn)]')).toBe(true)
    expect(el?.getAttribute('data-count-badge-tone')).toBe('warn')
  })

  it('applies ok tone', () => {
    const container = renderCountBadge({ tone: 'ok' }, 'OK')
    const el = container.querySelector('span')
    expect(el?.classList.contains('bg-[var(--ok-10)]')).toBe(true)
  })

  it('applies custom class', () => {
    const className = 'ml-2'
    const container = renderCountBadge({ class: className }, '3')
    const el = container.querySelector('span')
    expect(el?.classList.contains(className)).toBe(true)
    expect(el?.getAttribute('data-count-badge-has-custom-class')).toBe('true')
    expect(el?.getAttribute('data-count-badge-custom-class-length')).toBe(String(className.length))
  })
})
