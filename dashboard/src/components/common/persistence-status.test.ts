import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { PersistenceStatus } from './persistence-status'

describe('PersistenceStatus', () => {
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
})
