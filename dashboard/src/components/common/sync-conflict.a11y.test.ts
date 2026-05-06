// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { SyncConflict } from './sync-conflict'

describe('SyncConflict a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeConflicts = (): import('./sync-conflict').ConflictEntry[] => [
    { field: 'config.timeout', localValue: '5000', remoteValue: '10000', mergedValue: '7500' },
    { field: 'config.retry', localValue: '3', remoteValue: '5' },
  ]

  it('renders accessibly with conflicts', async () => {
    render(
      html`<${SyncConflict}
        conflicts=${makeConflicts()}
        onResolve=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty conflicts', async () => {
    render(
      html`<${SyncConflict} conflicts=${[]} onResolve=${() => {}} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('shows conflict count', () => {
    render(
      html`<${SyncConflict}
        conflicts=${makeConflicts()}
        onResolve=${() => {}}
      />`,
      container,
    )
    expect(container.textContent).toContain('동기화 충돌')
    expect(container.textContent).toContain('config.timeout')
    expect(container.textContent).toContain('로컬')
    expect(container.textContent).toContain('원격')
    expect(container.textContent).toContain('남음')
  })

  it('has region role', () => {
    render(
      html`<${SyncConflict}
        conflicts=${makeConflicts()}
        onResolve=${() => {}}
      />`,
      container,
    )
    const region = container.querySelector('[role="region"]') as HTMLElement
    expect(region).not.toBeNull()
    expect(region.getAttribute('aria-describedby')).toMatch(/sync-conflict-summary/)
    expect(region.dataset.syncConflictStatus).toBe('partial')
    expect(region.dataset.syncConflictActionRequired).toBe('true')
  })

  it('labels row resolution state for assistive review', () => {
    render(
      html`<${SyncConflict}
        conflicts=${makeConflicts()}
        onResolve=${() => {}}
      />`,
      container,
    )
    const resolved = container.querySelector('[data-sync-conflict-field="config.timeout"]')
    const unresolved = container.querySelector('[data-sync-conflict-field="config.retry"]')
    expect(resolved?.getAttribute('aria-label')).toContain('해결됨')
    expect(unresolved?.getAttribute('aria-label')).toContain('미해결')
  })

  it('has merge apply button', () => {
    render(
      html`<${SyncConflict}
        conflicts=${makeConflicts()}
        onResolve=${() => {}}
      />`,
      container,
    )
    const btn = container.querySelector('button[aria-label="병합 적용"]')
    expect(btn).not.toBeNull()
  })

  it('announces empty conflicts as a status', () => {
    render(
      html`<${SyncConflict} conflicts=${[]} onResolve=${() => {}} />`,
      container,
    )
    const status = container.querySelector('[role="status"]')
    const btn = container.querySelector('button[aria-label="병합 적용"]') as HTMLButtonElement
    expect(status?.textContent).toContain('충돌 없음')
    expect(btn.disabled).toBe(true)
  })
})
