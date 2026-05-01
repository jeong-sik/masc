import { describe, it, expect } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { StatusBadge, statusBadgeTone, statusDotColor } from './status-badge'

describe('statusDotColor', () => {
  it('returns warn for in_progress', () => {
    expect(statusDotColor('in_progress')).toBe('bg-[var(--color-status-warn)]')
  })

  it('normalizes hyphenated in-progress states', () => {
    expect(statusDotColor('in-progress')).toBe('bg-[var(--color-status-warn)]')
    expect(statusBadgeTone('claimed')).toBe('warn')
  })

  it('returns warn for running', () => {
    expect(statusDotColor('running')).toBe('bg-[var(--color-status-warn)]')
  })

  it('returns info for awaiting_verification', () => {
    expect(statusDotColor('awaiting_verification')).toBe('bg-[var(--color-status-info)]')
  })

  it('returns info for interrupted', () => {
    expect(statusDotColor('interrupted')).toBe('bg-[var(--color-status-info)]')
  })

  it('returns info for listening', () => {
    expect(statusDotColor('listening')).toBe('bg-[var(--color-status-info)]')
  })

  it('returns idle for inactive', () => {
    expect(statusDotColor('inactive')).toBe('bg-[var(--color-status-idle)]')
  })

  it('returns idle for offline', () => {
    expect(statusDotColor('offline')).toBe('bg-[var(--color-status-idle)]')
  })

  it('returns ok for active', () => {
    expect(statusDotColor('active')).toBe('bg-[var(--color-status-ok)]')
  })

  it('returns warn for busy', () => {
    expect(statusDotColor('busy')).toBe('bg-[var(--color-status-warn)]')
  })

  it('returns warn for paused', () => {
    expect(statusDotColor('paused')).toBe('bg-[var(--color-status-warn)]')
    expect(statusBadgeTone('paused')).toBe('warn')
  })

  it('returns idle for stopped', () => {
    expect(statusDotColor('stopped')).toBe('bg-[var(--color-status-idle)]')
  })

  it('returns bad for error', () => {
    expect(statusDotColor('error')).toBe('bg-[var(--color-status-err)]')
    expect(statusDotColor('failed')).toBe('bg-[var(--color-status-err)]')
  })

  it('returns muted for unknown status', () => {
    expect(statusDotColor('unknown')).toBe('bg-[var(--color-status-idle)]')
    expect(statusDotColor('')).toBe('bg-[var(--color-status-idle)]')
  })
})

describe('statusBadgeTone', () => {
  it('keeps semantic status groups explicit', () => {
    expect(statusBadgeTone('active')).toBe('ok')
    expect(statusBadgeTone('running')).toBe('warn')
    expect(statusBadgeTone('paused')).toBe('warn')
    expect(statusBadgeTone('listening')).toBe('info')
    expect(statusBadgeTone('offline')).toBe('neutral')
    expect(statusBadgeTone('error')).toBe('bad')
  })
})

describe('StatusBadge', () => {
  it('renders the status-badge utility and resolved tone hook', () => {
    const container = document.createElement('div')
    render(h(StatusBadge, { status: 'active' }), container)
    const el = container.querySelector('[data-status-badge-tone]')
    expect(el?.classList.contains('status-badge')).toBe(true)
    expect(el?.getAttribute('data-status-badge-tone')).toBe('ok')
    expect(el?.getAttribute('data-status-badge-status')).toBe('active')
    expect(el?.classList.contains('ok')).toBe(true)
    expect(el?.classList.contains('active')).toBe(false)
  })

  it('keeps resolved tone styling for statuses without explicit CSS variants', () => {
    const container = document.createElement('div')
    render(h(StatusBadge, { status: 'awaiting_verification' }), container)
    const el = container.querySelector('[data-status-badge-tone]')
    expect(el?.getAttribute('data-status-badge-tone')).toBe('info')
    expect(el?.getAttribute('data-status-badge-status')).toBe('awaiting-verification')
    expect(el?.classList.contains('info')).toBe(true)
    expect(el?.classList.contains('awaiting-verification')).toBe(false)
  })

  it('accepts tone plus children for caller-owned labels', () => {
    const container = document.createElement('div')
    render(h(StatusBadge, { tone: 'warn' }, 'cooldown'), container)
    const el = container.querySelector('[data-status-badge-tone]')
    expect(el?.textContent).toContain('cooldown')
    expect(el?.classList.contains('warn')).toBe(true)
  })

  it('does not override offline utility colors inline', () => {
    const container = document.createElement('div')
    render(h(StatusBadge, { status: 'offline' }), container)
    const el = container.querySelector('[data-status-badge-tone]')
    expect(el?.getAttribute('data-status-badge-status')).toBe('offline')
    expect(el?.classList.contains('offline')).toBe(false)
    expect(el?.className).not.toContain('text-[var(--color-fg-disabled)]')
  })

  it('lets the status-badge utility own the border', () => {
    const container = document.createElement('div')
    render(h(StatusBadge, { status: 'active' }), container)
    const el = container.querySelector('[data-status-badge-tone]')
    expect(el?.className).not.toContain('border-[var(--color-border-default)]')
    expect(el?.className).not.toContain('border-solid')
  })
})
