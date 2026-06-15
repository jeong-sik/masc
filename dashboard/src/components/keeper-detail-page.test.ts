import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import { keepers } from '../store'
import type { Keeper } from '../types'
import { KeeperContextRail, KeeperDetailRosterRail } from './keeper-detail-page'

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    status: 'active',
    phase: 'Running',
    lifecycle_phase: 'Running',
    model: 'claude-sonnet-4',
    runtime_id: 'oas-seoul-1',
    short_goal: 'runtime lane cleanup',
    context_ratio: 0.62,
    context_tokens: 124_000,
    context_max: 200_000,
    goal_progress: {
      active_goal_count: 1,
      linked_task_count: 3,
      open_task_count: 2,
      done_task_count: 1,
      blocked_task_count: 0,
      convergence: 0.5,
    },
    recent_tool_names: ['masc_trace_window', 'masc_board_metrics'],
    ...overrides,
  } as Keeper
}

function renderInto(ui: ReturnType<typeof html>) {
  const container = document.createElement('div')
  render(ui, container)
  return container
}

afterEach(() => {
  keepers.value = []
})

describe('KeeperDetailRosterRail', () => {
  it('renders the selected keeper list with status counts and search', () => {
    keepers.value = [
      makeKeeper(),
      makeKeeper({ name: 'rama', status: 'paused', phase: 'Paused', lifecycle_phase: 'Paused' }),
      makeKeeper({ name: 'dust', status: 'offline', phase: 'Stopped', lifecycle_phase: 'Stopped' }),
    ]

    const container = renderInto(html`<${KeeperDetailRosterRail} activeKeeperName="sangsu" />`)

    expect(container.textContent).toContain('3 / 3')
    expect(container.textContent).toContain('실행 1')
    expect(container.textContent).toContain('정지 1')
    expect(container.textContent).toContain('오프 1')
    expect(container.querySelector('input[name="keeper_detail_roster_search"]')).not.toBeNull()
    expect(container.querySelector('[aria-current="page"]')?.textContent).toContain('sangsu')
  })
})

describe('KeeperContextRail', () => {
  it('renders current keeper runtime, context, task, and tool summary', () => {
    const container = renderInto(html`<${KeeperContextRail} keeper=${makeKeeper()} />`)

    expect(container.textContent).toContain('현재 Keeper')
    expect(container.textContent).toContain('claude-sonnet-4')
    expect(container.textContent).toContain('oas-seoul-1')
    expect(container.textContent).toContain('62%')
    expect(container.textContent).toContain('열림 2')
    expect(container.textContent).toContain('완료 1')
    expect(container.textContent).toContain('masc_trace_window')
  })
})
