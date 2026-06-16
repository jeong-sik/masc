import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import { keepers, tasks } from '../store'
import type { Keeper, Task } from '../types'
import { KeeperWorkspaceRail } from './keeper-workspace/keeper-workspace-rail'
import { KeeperWorkspaceRoster } from './keeper-workspace/keeper-workspace-roster'

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    status: 'active',
    phase: 'Running',
    lifecycle_phase: 'Running',
    active_model_label: 'claude-sonnet-4',
    runtime_canonical: 'oas-seoul-1',
    short_goal: 'runtime lane cleanup',
    context_ratio: 0.62,
    context_tokens: 124_000,
    context_max: 200_000,
    recent_tool_names: ['masc_trace_window', 'masc_board_metrics'],
    ...overrides,
  } as Keeper
}

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'T-1',
    title: 'runtime lane cleanup',
    status: 'in_progress',
    assignee: 'sangsu',
    ...overrides,
  } as Task
}

function renderInto(ui: ReturnType<typeof html>) {
  const container = document.createElement('div')
  render(ui, container)
  return container
}

afterEach(() => {
  keepers.value = []
  tasks.value = []
})

describe('KeeperWorkspaceRoster', () => {
  it('renders the selected keeper list with status counts and search', () => {
    keepers.value = [
      makeKeeper(),
      makeKeeper({ name: 'rama', status: 'paused', phase: 'Paused', lifecycle_phase: 'Paused' }),
      makeKeeper({ name: 'dust', status: 'offline', phase: 'Stopped', lifecycle_phase: 'Stopped' }),
    ]

    const container = renderInto(html`<${KeeperWorkspaceRoster} activeName="sangsu" />`)

    expect(container.textContent).toContain('전체3')
    expect(container.textContent).toContain('실행중1')
    expect(container.textContent).toContain('실행 중')
    expect(container.textContent).toContain('대기 · 일시정지')
    expect(container.textContent).toContain('중지 · 종료됨')
    expect(container.querySelector('.kw-roster-search')).not.toBeNull()
    expect(container.querySelector('[aria-current="true"]')?.textContent).toContain('sangsu')
  })
})

describe('KeeperWorkspaceRail', () => {
  it('renders current keeper runtime, context, and owned task', () => {
    tasks.value = [makeTask()]
    const container = renderInto(html`<${KeeperWorkspaceRail} keeper=${makeKeeper()} onToggleDetail=${() => {}} />`)

    expect(container.textContent).toContain('런타임 · 처리량')
    expect(container.textContent).toContain('claude-sonnet-4')
    expect(container.textContent).toContain('oas-seoul-1')
    expect(container.textContent).toContain('62%')
    expect(container.textContent).toContain('T-1')
    // The rail no longer renders keeper.recent_tool_names; #21266 migrated the
    // recent-tool section to KeeperWorkspaceRecentTools, which lazy-loads per-call
    // data via fetchKeeperToolCalls and returns null when nothing is fetched. That
    // behavior is covered (with the fetch stubbed) in keeper-workspace-tool-calls.test.ts
    // and keeper-workspace-rail.test.ts; asserting recent_tool_names here tested
    // removed behavior. Do not re-add a fetch mock + tool assertion (would duplicate
    // canonical coverage).
  })
})
