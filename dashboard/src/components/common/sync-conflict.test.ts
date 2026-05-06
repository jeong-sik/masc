import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  getConflictResolutionState,
  isConflictResolved,
  summarizeSyncConflicts,
  SyncConflict,
} from './sync-conflict'

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
    expect(container.textContent).toContain('전체')
    expect(container.textContent).toContain('해결')
    expect(container.textContent).toContain('남음')
  })

  it('exposes conflict summary metadata', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {}, testId: 'sc-1' }), container)
    const root = container.querySelector('[data-sync-conflict]') as HTMLElement

    expect(root.dataset.syncConflictCount).toBe('2')
    expect(root.dataset.syncConflictResolvedCount).toBe('1')
    expect(root.dataset.syncConflictUnresolvedCount).toBe('1')
    expect(root.dataset.syncConflictStatus).toBe('partial')
    expect(root.dataset.syncConflictActionRequired).toBe('true')
  })

  it('marks each row with resolution state and diff side metadata', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {} }), container)
    const nameRow = container.querySelector('[data-sync-conflict-field="name"]') as HTMLElement
    const ageRow = container.querySelector('[data-sync-conflict-field="age"]') as HTMLElement

    expect(nameRow.dataset.syncConflictResolutionState).toBe('unresolved')
    expect(nameRow.getAttribute('aria-label')).toContain('미해결')
    expect(ageRow.dataset.syncConflictResolutionState).toBe('resolved')
    expect(ageRow.getAttribute('aria-label')).toContain('해결됨')
    expect(container.querySelectorAll('[data-sync-conflict-side="local"]').length).toBe(2)
    expect(container.querySelectorAll('[data-sync-conflict-side="remote"]').length).toBe(2)
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

  it('shows an empty state and disables apply when no conflicts exist', () => {
    const onResolve = vi.fn()
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts: [], onResolve }), container)
    const root = container.querySelector('[data-sync-conflict]') as HTMLElement
    const btn = container.querySelector('button[aria-label="병합 적용"]') as HTMLButtonElement

    expect(root.dataset.syncConflictStatus).toBe('empty')
    expect(root.dataset.syncConflictActionRequired).toBe('false')
    expect(container.textContent).toContain('충돌 없음')
    expect(container.querySelector('[role="list"]')).toBeNull()
    expect(btn.disabled).toBe(true)
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(SyncConflict, { conflicts, onResolve: () => {}, testId: 'sc-1' }), container)
    expect(container.querySelector('[data-testid="sc-1"]')).not.toBeNull()
  })

  it('summarizes conflicts without rendering', () => {
    const summary = summarizeSyncConflicts(conflicts)

    expect(summary).toEqual({
      totalCount: 2,
      resolvedCount: 1,
      unresolvedCount: 1,
      status: 'partial',
      actionRequired: true,
      fields: ['name', 'age'],
      resolvedFields: ['age'],
      unresolvedFields: ['name'],
    })
  })

  it('summarizes explicit edits as resolved', () => {
    const summary = summarizeSyncConflicts(conflicts, { name: 'Alice Bob' })

    expect(summary.status).toBe('resolved')
    expect(summary.actionRequired).toBe(false)
    expect(summary.resolvedFields).toEqual(['name', 'age'])
    expect(summary.unresolvedFields).toEqual([])
    expect(isConflictResolved(conflicts[0]!, { name: '' })).toBe(true)
    expect(getConflictResolutionState(conflicts[0]!)).toBe('unresolved')
  })
})
