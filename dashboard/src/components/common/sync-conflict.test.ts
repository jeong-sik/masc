import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { SyncConflict } from './sync-conflict'

describe('SyncConflict', () => {
  const conflicts = [
    { field: 'name', localValue: 'Alice', remoteValue: 'Bob' },
    { field: 'age', localValue: '30', remoteValue: '31', mergedValue: '30' },
  ]

  it('renders region role', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {} }), container)
    expect(container.querySelector('[role="region"]')).not.toBeNull()
  })

  it('renders all conflict entries', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {} }), container)
    const items = container.querySelectorAll('[role="listitem"]')
    expect(items.length).toBe(2)
    expect(container.textContent).toContain('Alice')
    expect(container.textContent).toContain('Bob')
    expect(container.textContent).toContain('30')
    expect(container.textContent).toContain('31')
  })

  it('shows resolved count', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {} }), container)
    expect(container.textContent).toContain('동기화 충돌 (1/2)')
  })

  it('shows local and remote labels', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {} }), container)
    expect(container.textContent).toContain('로컬')
    expect(container.textContent).toContain('원격')
  })

  it('shows merge label', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {} }), container)
    expect(container.textContent).toContain('병합:')
  })

  it('calls onResolve on button click', async () => {
    const onResolve = vi.fn()
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve }), container)
    const btn = container.querySelector('button[aria-label="병합 적용"]') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onResolve).toHaveBeenCalledOnce()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {}, testId: 'sc-1' }), container)
    expect(container.querySelector('[data-testid="sc-1"]')).not.toBeNull()
  })
})
