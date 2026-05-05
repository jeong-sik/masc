import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { IdeKeeperWorkPanel, keeperWorkSummary } from './ide-keeper-work-panel'
import { keepers, tasks } from '../../store'
import type { Keeper, Task } from '../../types'

describe('IdeKeeperWorkPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
  })

  afterEach(() => {
    render(null, container)
    keepers.value = []
    tasks.value = []
  })

  it('summarizes the selected keeper current task and terminal reason', () => {
    keepers.value = [keeperFixture()]
    tasks.value = [taskFixture()]

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    expect(container.textContent).toContain('KEEPER WORK')
    expect(container.textContent).toContain('task-151')
    expect(container.textContent).toContain('Fix codex cascade config')
    expect(container.textContent).toContain('tool_required_unsatisfied')
    expect(container.textContent).toContain('inspect_provider_tool_contract')
    expect(container.textContent).toContain('masc_claim_next')
  })

  it('matches keeper-agent task assignees to the canonical keeper name', () => {
    const summary = keeperWorkSummary(
      'sangsu',
      [keeperFixture()],
      [taskFixture({ assignee: 'keeper-sangsu-agent' })],
    )

    expect(summary.currentTaskId).toBe('task-151')
    expect(summary.currentTask?.title).toBe('Fix codex cascade config')
    expect(summary.activeTasks).toHaveLength(1)
    expect(summary.activeTaskCount).toBe(1)
  })

  it('keeps runtime current_task visible when the task row is absent', () => {
    const summary = keeperWorkSummary('sangsu', [keeperFixture()], [])

    expect(summary.currentTaskId).toBe('task-151')
    expect(summary.currentTask).toBeNull()
    expect(summary.activeTaskCount).toBe(1)

    keepers.value = [keeperFixture()]
    tasks.value = []

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    expect(container.textContent).toContain('task-151')
    expect(container.textContent).toContain('keeper runtime current task')
    expect(container.textContent).not.toContain('no active keeper task')
  })
})

function keeperFixture(): Keeper {
  return {
    name: 'sangsu',
    keeper_id: 'keeper-id-sangsu',
    agent_name: 'keeper-sangsu-agent',
    status: 'running',
    phase: 'Failing',
    needs_attention: true,
    agent: {
      name: 'keeper-sangsu-agent',
      current_task: 'task-151',
    },
    trust: {
      needs_attention: true,
      latest_terminal_reason: {
        code: 'tool_required_unsatisfied',
        summary: 'actionable keeper signal was present, but no keeper tools were called',
        next_action: 'inspect_provider_tool_contract',
      },
    },
    recent_output_preview: 'required tool contract violated',
    recent_tool_names: ['masc_claim_next', 'masc_board_list'],
  } as Keeper
}

function taskFixture(partial: Partial<Task> = {}): Task {
  return {
    id: 'task-151',
    title: 'Fix codex cascade config',
    status: 'claimed',
    assignee: 'sangsu',
    worktree: {
      branch: 'fix/cascade',
      path: '/workspace/.worktrees/fix-cascade',
      git_root: '/workspace',
      repo_name: 'masc-mcp',
    },
    ...partial,
  }
}
