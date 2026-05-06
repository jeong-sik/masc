// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { PersistenceStatus } from './persistence-status'

describe('PersistenceStatus a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly in saved state', async () => {
    render(html`<${PersistenceStatus} status="saved" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly in syncing state', async () => {
    render(html`<${PersistenceStatus} status="syncing" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly in conflict state', async () => {
    render(html`<${PersistenceStatus} status="conflict" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly in offline state', async () => {
    render(html`<${PersistenceStatus} status="offline" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with lastSaved timestamp', async () => {
    render(
      html`<${PersistenceStatus} status="saved" lastSaved="2026-04-30T08:00:00Z" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('exposes role="status" for screen readers', () => {
    render(html`<${PersistenceStatus} status="syncing" testId="ps" />`, container)
    const el = container.querySelector('[data-testid="ps"]') as HTMLElement
    expect(el.getAttribute('role')).toBe('status')
    expect(el.getAttribute('aria-live')).toBe('polite')
    expect(el.getAttribute('aria-busy')).toBe('true')
  })

  it('contains the correct label text for each state', () => {
    const states = [
      { status: 'saved', label: '저장됨' },
      { status: 'syncing', label: '동기화 중' },
      { status: 'conflict', label: '충돌' },
      { status: 'offline', label: '오프라인' },
    ] as const

    for (const { status, label } of states) {
      render(null, container)
      render(html`<${PersistenceStatus} status=${status} />`, container)
      expect(container.textContent).toContain(label)
    }
  })

  it('exposes state, freshness, and action metadata', () => {
    render(
      html`<${PersistenceStatus}
        status="conflict"
        lastSaved="2026-05-05T22:00:00Z"
        now="2026-05-06T00:00:00Z"
      />`,
      container,
    )
    const el = container.querySelector('[data-persistence-status]')
    expect(el?.getAttribute('data-persistence-state')).toBe('conflict')
    expect(el?.getAttribute('data-persistence-severity')).toBe('attention')
    expect(el?.getAttribute('data-persistence-freshness')).toBe('stale')
    expect(el?.getAttribute('data-persistence-action-required')).toBe('true')
    expect(el?.getAttribute('aria-label')).toContain('오래됨')
  })

  it('renders machine-readable time metadata when lastSaved is valid', () => {
    render(
      html`<${PersistenceStatus}
        status="saved"
        lastSaved="2026-05-05T23:58:00Z"
        now="2026-05-06T00:00:00Z"
      />`,
      container,
    )
    const time = container.querySelector('time[data-persistence-time]')
    expect(time?.getAttribute('datetime')).toBe('2026-05-05T23:58:00.000Z')
    expect(container.querySelector('[data-persistence-freshness-label]')?.textContent).toBe('최신')
  })
})
