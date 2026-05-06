import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  getVersionSnapshotState,
  shortSnapshotId,
  summarizeVersionHistory,
  VersionHistory,
} from './version-history'

describe('VersionHistory', () => {
  const snapshots = [
    {
      id: 'snap-a',
      timestamp: Date.now() - 1000,
      author: 'Alice',
      message: 'First',
      changes: { added: 2, modified: 1, deleted: 0 },
    },
    {
      id: 'snap-b',
      timestamp: Date.now() - 60000,
      author: 'Bob',
      message: 'Second',
      changes: { added: 0, modified: 3, deleted: 1 },
    },
  ]

  it('renders list role', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a' }), container)
    expect(container.querySelector('[role="list"]')).not.toBeNull()
  })

  it('renders all snapshots', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a' }), container)
    const items = container.querySelectorAll('[role="listitem"]')
    expect(items.length).toBe(2)
    expect(container.textContent).toContain('First')
    expect(container.textContent).toContain('Second')
  })

  it('marks current snapshot', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a' }), container)
    expect(container.textContent).toContain('현재')
  })

  it('shows rollback button for non-current', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a', onRollback: () => {} }), container)
    const buttons = container.querySelectorAll('button')
    expect(buttons.length).toBe(1)
    expect(buttons[0]?.textContent).toContain('이 상태로 롤백')
  })

  it('exposes version history summary metadata', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a', onRollback: () => {}, testId: 'vh-1' }), container)
    const root = container.querySelector('[data-version-history]') as HTMLElement

    expect(root.dataset.versionHistoryCount).toBe('2')
    expect(root.dataset.versionHistoryCurrentId).toBe('snap-a')
    expect(root.dataset.versionHistoryCurrentIndex).toBe('0')
    expect(root.dataset.versionHistoryStatus).toBe('current')
    expect(root.dataset.versionHistoryRollbackCount).toBe('1')
    expect(root.dataset.versionHistoryAdded).toBe('2')
    expect(root.dataset.versionHistoryModified).toBe('4')
    expect(root.dataset.versionHistoryDeleted).toBe('1')
    expect(root.getAttribute('aria-describedby')).toMatch(/version-history-summary/)
  })

  it('marks snapshot rows with current state and change metadata', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a' }), container)
    const current = container.querySelector('[data-version-snapshot-id="snap-a"]') as HTMLElement
    const historical = container.querySelector('[data-version-snapshot-id="snap-b"]') as HTMLElement

    expect(current.dataset.versionSnapshotCurrent).toBe('true')
    expect(current.dataset.versionSnapshotState).toBe('current')
    expect(current.getAttribute('aria-current')).toBe('step')
    expect(current.querySelector('time')?.getAttribute('datetime')).toBeTruthy()
    expect(historical.dataset.versionSnapshotCurrent).toBe('false')
    expect(historical.dataset.versionSnapshotState).toBe('historical')
    expect(historical.getAttribute('aria-current')).toBeNull()
    expect(historical.dataset.versionSnapshotModified).toBe('3')
  })

  it('calls onRollback on click', async () => {
    const onRollback = vi.fn()
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a', onRollback }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onRollback).toHaveBeenCalledWith('snap-b')
  })

  it('renders author and stats', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a' }), container)
    expect(container.textContent).toContain('Alice')
    expect(container.textContent).toContain('Bob')
    expect(container.textContent).toContain('+2')
    expect(container.textContent).toContain('~3')
    expect(container.textContent).toContain('-1')
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a' }), container)
    const list = container.querySelector('[role="list"]')
    expect(list?.getAttribute('aria-label')).toBe('버전 히스토리')
  })

  it('renders an empty state when there are no snapshots', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots: [], currentId: '' }), container)
    const root = container.querySelector('[data-version-history]') as HTMLElement

    expect(root.dataset.versionHistoryStatus).toBe('empty')
    expect(root.dataset.versionHistoryCount).toBe('0')
    expect(container.textContent).toContain('스냅샷 없음')
    expect(container.querySelector('[role="status"]')).not.toBeNull()
    expect(container.querySelector('[role="list"]')).toBeNull()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a', testId: 'vh-1' }), container)
    expect(container.querySelector('[data-testid="vh-1"]')).not.toBeNull()
  })

  it('summarizes version history without rendering', () => {
    const summary = summarizeVersionHistory(snapshots, 'snap-a', true)

    expect(summary.totalCount).toBe(2)
    expect(summary.currentId).toBe('snap-a')
    expect(summary.currentIndex).toBe(0)
    expect(summary.currentShortId).toBe('snap-a')
    expect(summary.status).toBe('current')
    expect(summary.hasCurrent).toBe(true)
    expect(summary.rollbackCount).toBe(1)
    expect(summary.totalAdded).toBe(2)
    expect(summary.totalModified).toBe(4)
    expect(summary.totalDeleted).toBe(1)
    expect(summary.newestTimestamp!).toBeGreaterThanOrEqual(summary.oldestTimestamp!)
    expect(shortSnapshotId('abcdef12345')).toBe('abcdef1')
    expect(shortSnapshotId('snap-001-alpha', ['snap-001-alpha', 'snap-002-beta'])).toBe('snap-001')
    expect(getVersionSnapshotState(snapshots[0]!, 'snap-a')).toBe('current')
    expect(getVersionSnapshotState(snapshots[1]!, 'snap-a')).toBe('historical')
  })

  it('summarizes a missing current id', () => {
    const summary = summarizeVersionHistory(snapshots, 'missing')

    expect(summary.status).toBe('missing-current')
    expect(summary.hasCurrent).toBe(false)
    expect(summary.currentIndex).toBe(-1)
    expect(summary.currentShortId).toBeNull()
    expect(summary.rollbackCount).toBe(0)
  })
})
