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
  })

  it('has region role', () => {
    render(
      html`<${SyncConflict}
        conflicts=${makeConflicts()}
        onResolve=${() => {}}
      />`,
      container,
    )
    expect(container.querySelector('[role="region"]')).not.toBeNull()
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
})
