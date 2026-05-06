// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { VersionHistory } from './version-history'

describe('VersionHistory a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeSnapshots = (): import('./version-history').VersionSnapshot[] => [
    {
      id: 'snap-001-aaa',
      timestamp: Date.now() - 3600000,
      author: 'agent-alpha',
      message: 'Initialize memory index',
      changes: { added: 12, modified: 0, deleted: 0 },
    },
    {
      id: 'snap-002-bbb',
      timestamp: Date.now() - 1800000,
      author: 'agent-beta',
      message: 'Merge conflict resolution',
      changes: { added: 3, modified: 7, deleted: 1 },
    },
    {
      id: 'snap-003-ccc',
      timestamp: Date.now() - 600000,
      author: 'agent-gamma',
      message: 'Compact long-term store',
      changes: { added: 0, modified: 2, deleted: 5 },
    },
  ]

  it('renders accessibly with snapshots', async () => {
    render(
      html`<${VersionHistory}
        snapshots=${makeSnapshots()}
        currentId="snap-002-bbb"
        onRollback=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty snapshots', async () => {
    render(
      html`<${VersionHistory} snapshots=${[]} currentId="" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly without onRollback', async () => {
    render(
      html`<${VersionHistory}
        snapshots=${makeSnapshots()}
        currentId="snap-003-ccc"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('marks current snapshot with 현재 badge', () => {
    render(
      html`<${VersionHistory}
        snapshots=${makeSnapshots()}
        currentId="snap-002-bbb"
      />`,
      container,
    )
    expect(container.textContent).toContain('현재')
    expect(container.querySelector('[aria-current="step"]')?.getAttribute('data-version-snapshot-id')).toBe('snap-002-bbb')
  })

  it('shows rollback buttons for non-current snapshots when handler provided', () => {
    render(
      html`<${VersionHistory}
        snapshots=${makeSnapshots()}
        currentId="snap-002-bbb"
        onRollback=${() => {}}
      />`,
      container,
    )
    const buttons = container.querySelectorAll('button')
    expect(buttons.length).toBe(2)
  })

  it('has list role', () => {
    render(
      html`<${VersionHistory}
        snapshots=${makeSnapshots()}
        currentId="snap-002-bbb"
      />`,
      container,
    )
    const list = container.querySelector('[role="list"]')
    const region = container.querySelector('[data-version-history]') as HTMLElement
    expect(list).not.toBeNull()
    expect(list?.getAttribute('aria-label')).toBe('버전 히스토리')
    expect(region.getAttribute('aria-describedby')).toMatch(/version-history-summary/)
    expect(region.dataset.versionHistoryStatus).toBe('current')
  })

  it('renders change counts', () => {
    render(
      html`<${VersionHistory}
        snapshots=${makeSnapshots()}
        currentId="snap-002-bbb"
      />`,
      container,
    )
    expect(container.textContent).toContain('+12')
    expect(container.textContent).toContain('~7')
    expect(container.textContent).toContain('-1')
  })

  it('exposes row metadata for assistive review', () => {
    render(
      html`<${VersionHistory}
        snapshots=${makeSnapshots()}
        currentId="snap-002-bbb"
        onRollback=${() => {}}
      />`,
      container,
    )
    const first = container.querySelector('[data-version-snapshot-id="snap-001-aaa"]')
    const current = container.querySelector('[data-version-snapshot-id="snap-002-bbb"]')
    expect(first?.getAttribute('aria-label')).toContain('이전 버전')
    expect(first?.getAttribute('data-version-snapshot-added')).toBe('12')
    expect(current?.getAttribute('aria-label')).toContain('현재 버전')
    expect(current?.getAttribute('data-version-snapshot-state')).toBe('current')
  })

  it('announces the empty state', () => {
    render(
      html`<${VersionHistory} snapshots=${[]} currentId="" />`,
      container,
    )
    const root = container.querySelector('[data-version-history]') as HTMLElement
    const status = container.querySelector('[role="status"]')
    expect(root.dataset.versionHistoryStatus).toBe('empty')
    expect(status?.textContent).toContain('스냅샷 없음')
  })
})
