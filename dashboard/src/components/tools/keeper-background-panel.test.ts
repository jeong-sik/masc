import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type {
  DashboardKeeperBackground,
  DashboardKeeperBackgroundKeeper,
  DashboardKeeperRecurringTask,
} from '../../api'
import { KeeperBackgroundPanel } from './keeper-background-panel'

function task(overrides: Partial<DashboardKeeperRecurringTask> & { id: string }): DashboardKeeperRecurringTask {
  return {
    label: 'board 감시',
    action_kind: 'broadcast',
    interval_sec: 3600,
    enabled: true,
    run_count: 0,
    failure_count: 0,
    max_failures: 0,
    ...overrides,
  }
}

function keeper(
  overrides: Partial<DashboardKeeperBackgroundKeeper> & { keeper_name: string },
): DashboardKeeperBackgroundKeeper {
  return {
    loop: { phase: 'running', restart_count: 0 },
    recurring: [],
    recurring_count: 0,
    ...overrides,
  }
}

function data(keepers: DashboardKeeperBackgroundKeeper[]): DashboardKeeperBackground {
  return {
    schema: 'masc.dashboard.keeper_background.v1',
    keeper_count: keepers.length,
    recurring_keeper_count: keepers.length,
    recurring_count: keepers.reduce((sum, k) => sum + k.recurring.length, 0),
    keepers,
  }
}

describe('KeeperBackgroundPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('shows the empty state when no keeper has recurring work', () => {
    render(html`<${KeeperBackgroundPanel} data=${data([])} />`, container)
    expect(container.querySelector('[data-testid="keeper-background-empty"]')).not.toBeNull()
    // The sub-line always points at the waiting inventory for async/deferred work.
    expect(container.textContent).toContain('Keeper Waiting Inventory')
  })

  it('renders a keeper group with its recurring tasks and loop context', () => {
    const k = keeper({
      keeper_name: 'watcher',
      loop: { phase: 'running', restart_count: 2, started_at_iso: '2026-07-07T05:00:00Z' },
      recurring: [task({ id: 't1', label: '보드 스윕', interval_sec: 21600, run_count: 4 })],
      recurring_count: 1,
    })
    render(html`<${KeeperBackgroundPanel} data=${data([k])} />`, container)

    const group = container.querySelector('[data-keeper-name="watcher"]')
    expect(group).not.toBeNull()
    expect(group?.textContent).toContain('running')
    expect(group?.textContent).toContain('restart 2')
    const task1 = container.querySelector('[data-task-id="t1"]')
    expect(task1?.textContent).toContain('보드 스윕')
    expect(task1?.textContent).toContain('매 6h')
    expect(task1?.textContent).toContain('실행 4')
  })

  it('reports honest absence for a never-run task and pause for a disabled one', () => {
    const neverRun = keeper({
      keeper_name: 'fresh',
      recurring: [task({ id: 'n1', enabled: true })],
      recurring_count: 1,
    })
    render(html`<${KeeperBackgroundPanel} data=${data([neverRun])} />`, container)
    expect(container.querySelector('[data-task-id="n1"]')?.textContent).toContain('실행 이력 없음')
    expect(container.querySelector('[data-task-id="n1"]')?.textContent).toContain('다음 tick 대기')

    const paused = keeper({
      keeper_name: 'paused-keeper',
      recurring: [task({ id: 'p1', enabled: false, last_run_at_iso: '2026-07-07T05:00:00Z' })],
      recurring_count: 1,
    })
    render(html`<${KeeperBackgroundPanel} data=${data([paused])} />`, container)
    const row = container.querySelector('[data-task-id="p1"]')
    expect(row?.textContent).toContain('멈춤')
    expect(row?.textContent).toContain('멈춤 — 다음 없음')
  })
})
