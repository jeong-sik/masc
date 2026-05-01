import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { VersionHistory } from './version-history'

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

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(VersionHistory, { snapshots, currentId: 'snap-a', testId: 'vh-1' }), container)
    expect(container.querySelector('[data-testid="vh-1"]')).not.toBeNull()
  })
})
