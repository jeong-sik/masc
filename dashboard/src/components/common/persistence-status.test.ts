import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  classifyPersistenceFreshness,
  getPersistenceStatusConfig,
  PersistenceStatus,
  summarizePersistenceStatus,
} from './persistence-status'

describe('PersistenceStatus', () => {
  it('maps states to operator severity metadata', () => {
    expect(getPersistenceStatusConfig('saved').severity).toBe('ok')
    expect(getPersistenceStatusConfig('syncing').severity).toBe('busy')
    expect(getPersistenceStatusConfig('conflict').severity).toBe('attention')
    expect(getPersistenceStatusConfig('offline').severity).toBe('offline')
  })

  it('classifies timestamp freshness deterministically', () => {
    const now = '2026-05-06T00:00:00Z'
    expect(classifyPersistenceFreshness('2026-05-05T23:58:00Z', now)).toMatchObject({
      freshness: 'fresh',
      ageMs: 120000,
      lastSavedIso: '2026-05-05T23:58:00.000Z',
    })
    expect(classifyPersistenceFreshness('2026-05-05T23:58:00Z', 1778025600)).toMatchObject({
      freshness: 'fresh',
      ageMs: 120000,
      lastSavedIso: '2026-05-05T23:58:00.000Z',
    })
    expect(classifyPersistenceFreshness('2026-05-05T23:30:00Z', now).freshness).toBe('recent')
    expect(classifyPersistenceFreshness('2026-05-05T22:30:00Z', now).freshness).toBe('stale')
    expect(classifyPersistenceFreshness(null, now).freshness).toBe('unknown')
    expect(classifyPersistenceFreshness('not-a-date', now).lastSavedIso).toBeNull()
  })

  it('summarizes action-required states', () => {
    expect(summarizePersistenceStatus('saved').actionRequired).toBe(false)
    expect(summarizePersistenceStatus('syncing').actionRequired).toBe(false)
    expect(summarizePersistenceStatus('conflict').actionRequired).toBe(true)
    expect(summarizePersistenceStatus('offline').actionRequired).toBe(true)
  })

  it('renders role status', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'saved' }), container)
    expect(container.querySelector('[role="status"]')).not.toBeNull()
  })

  it('renders saved label', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'saved' }), container)
    expect(container.textContent).toContain('저장됨')
  })

  it('renders syncing label', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'syncing' }), container)
    expect(container.textContent).toContain('동기화 중')
  })

  it('renders conflict label', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'conflict' }), container)
    expect(container.textContent).toContain('충돌')
  })

  it('renders offline label', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'offline' }), container)
    expect(container.textContent).toContain('오프라인')
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'saved' }), container)
    const el = container.querySelector('[role="status"]')
    expect(el?.getAttribute('aria-label')).toContain('저장됨')
    expect(el?.getAttribute('aria-label')).toContain('시간 정보 없음')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'saved', testId: 'ps-1' }), container)
    expect(container.querySelector('[data-testid="ps-1"]')).not.toBeNull()
  })

  it('renders lastSaved time when provided', () => {
    const container = document.createElement('div')
    const ts = new Date(Date.now() - 60000).toISOString()
    render(h(PersistenceStatus, { status: 'saved', lastSaved: ts }), container)
    expect(container.textContent).toContain('전')
  })

  it('exposes machine-readable persistence metadata', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, {
      status: 'saved',
      lastSaved: '2026-05-05T23:58:00Z',
      now: '2026-05-06T00:00:00Z',
    }), container)
    const el = container.querySelector('[data-persistence-status]')
    expect(el?.getAttribute('data-persistence-state')).toBe('saved')
    expect(el?.getAttribute('data-persistence-severity')).toBe('ok')
    expect(el?.getAttribute('data-persistence-freshness')).toBe('fresh')
    expect(el?.getAttribute('data-persistence-action-required')).toBe('false')
    expect(el?.getAttribute('data-persistence-last-saved')).toBe('2026-05-05T23:58:00.000Z')
    expect(el?.getAttribute('data-persistence-age-ms')).toBe('120000')
    expect(container.querySelector('[data-persistence-freshness-label]')?.textContent).toBe('최신')
  })

  it('renders lastSaved as a time element with datetime', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, {
      status: 'saved',
      lastSaved: '2026-05-05T23:58:00Z',
      now: '2026-05-06T00:00:00Z',
    }), container)
    const time = container.querySelector('time[data-persistence-time]')
    expect(time?.getAttribute('datetime')).toBe('2026-05-05T23:58:00.000Z')
  })

  it('keeps rendered relative time aligned with provided now', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, {
      status: 'saved',
      lastSaved: '2026-05-05T23:58:00Z',
      now: '2026-05-06T00:00:00Z',
    }), container)
    expect(container.querySelector('[data-persistence-time]')?.textContent).toBe('2분 전')
    expect(container.querySelector('[data-persistence-status]')?.getAttribute('data-persistence-age-ms')).toBe('120000')
  })

  it('does not render raw invalid timestamps as time elements', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, {
      status: 'saved',
      lastSaved: 'not-a-date',
      now: '2026-05-06T00:00:00Z',
    }), container)
    expect(container.querySelector('time[data-persistence-time]')).toBeNull()
    expect(container.textContent).not.toContain('not-a-date')
    expect(container.querySelector('[data-persistence-status]')?.getAttribute('data-persistence-last-saved')).toBeNull()
  })

  it('marks syncing as busy for assistive tech', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'syncing' }), container)
    const el = container.querySelector('[role="status"]')
    expect(el?.getAttribute('aria-busy')).toBe('true')
    expect(el?.getAttribute('data-persistence-severity')).toBe('busy')
  })

  it('marks conflict and offline as action-required', () => {
    const container = document.createElement('div')
    render(h(PersistenceStatus, { status: 'conflict' }), container)
    expect(container.querySelector('[data-persistence-status]')?.getAttribute('data-persistence-action-required')).toBe('true')

    render(h(PersistenceStatus, { status: 'offline' }), container)
    expect(container.querySelector('[data-persistence-status]')?.getAttribute('data-persistence-action-required')).toBe('true')
  })
})
