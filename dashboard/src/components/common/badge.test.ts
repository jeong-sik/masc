import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { CountBadge } from './badge'

describe('CountBadge', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(CountBadge, null, '42'), container)
    expect(container.textContent).toBe('42')
  })

  it('applies default tone classes', () => {
    const container = document.createElement('div')
    render(h(CountBadge, null, '1'), container)
    const el = container.querySelector('span')
    expect(el).not.toBeNull()
    expect(el?.classList.contains('bg-[var(--white-8)]')).toBe(true)
    expect(el?.classList.contains('text-[var(--color-fg-muted)]')).toBe(true)
  })

  it('applies warn tone', () => {
    const container = document.createElement('div')
    render(h(CountBadge, { tone: 'warn' }, '!'), container)
    const el = container.querySelector('span')
    expect(el?.classList.contains('bg-[var(--warn-12)]')).toBe(true)
    expect(el?.classList.contains('text-[var(--color-status-warn)]')).toBe(true)
  })

  it('applies ok tone', () => {
    const container = document.createElement('div')
    render(h(CountBadge, { tone: 'ok' }, 'OK'), container)
    const el = container.querySelector('span')
    expect(el?.classList.contains('bg-[var(--ok-10)]')).toBe(true)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(CountBadge, { class: 'ml-2' }, '3'), container)
    const el = container.querySelector('span')
    expect(el?.classList.contains('ml-2')).toBe(true)
  })
})
