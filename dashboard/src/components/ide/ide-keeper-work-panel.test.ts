import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { IdeKeeperWorkPanel, keeperWorkSummary } from './ide-keeper-work-panel'
import { goals, keepers, tasks } from '../../store'
import type { Goal, Keeper, Task } from '../../types'

describe('IdeKeeperWorkPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
  })

  afterEach(() => {
    render(null, container)
    goals.value = []
    keepers.value = []
    tasks.value = []
    window.location.hash = ''
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

  it('shows the current task goal progress and links back to planning', () => {
    keepers.value = [keeperFixture()]
    goals.value = [goalFixture()]
    tasks.value = [
      taskFixture({ goal_id: 'goal-runtime', status: 'claimed' }),
      taskFixture({ id: 'task-done', title: 'Done task', goal_id: 'goal-runtime', status: 'done' }),
      taskFixture({ id: 'task-cancelled', title: 'Cancelled task', goal_id: 'goal-runtime', status: 'cancelled' }),
    ]

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    expect(container.textContent).toContain('GOAL PROGRESS')
    expect(container.textContent).toContain('Runtime goal')
    expect(container.textContent).toContain('1/2 tasks')
    expect(container.textContent).toContain('50%')
    expect(container.textContent).toContain('Goal')
    expect(container.textContent).toContain('Task')

    fireEvent.click(buttonByText(container, 'Goal'))
    expect(window.location.hash).toBe('#workspace?section=planning&goal=goal-runtime')
    fireEvent.click(buttonByText(container, 'Task'))
    expect(window.location.hash).toBe('#workspace?section=planning&view=default&task=task-151')
  })

  it('links the current task to git, telemetry, and keeper context', () => {
    keepers.value = [keeperFixture()]
    tasks.value = [taskFixture({
      goal_id: 'goal-runtime',
      execution_links: {
        session_id: 'sess-151',
        operation_id: 'op-151',
      },
    })]

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    const taskLinks = Array.from(
      container.querySelectorAll<HTMLButtonElement>('.ide-keeper-work-card .ide-keeper-work-links button'),
    )
    expect(taskLinks.map(link => link.textContent)).toEqual([
      'Goal',
      'Task',
      'Git',
      'Telemetry',
      'Keeper',
    ])
    expect(buttonByText(container, 'Git').title).toBe('Git fix/cascade')
    expect(buttonByText(container, 'Telemetry').title)
      .toBe('Fleet telemetry event log · session sess-151 · operation op-151 · query op-151')

    fireEvent.click(buttonByText(container, 'Telemetry'))
    expect(window.location.hash).toContain('#monitoring?section=fleet-health&view=event-log')
    expect(window.location.hash).toContain('session_id=sess-151')
    expect(window.location.hash).toContain('operation_id=op-151')
    expect(window.location.hash).toContain('q=op-151')
  })

  it('surfaces the rest of the active keeper task queue as routable work', () => {
    keepers.value = [keeperFixture()]
    tasks.value = [
      taskFixture({ goal_id: 'goal-runtime' }),
      taskFixture({
        id: 'task-next',
        title: 'Wire keeper queue context',
        status: 'in_progress',
        goal_id: 'goal-next',
        worktree: {
          branch: 'feat/keeper-queue',
          path: '/workspace/.worktrees/keeper-queue',
          git_root: '/workspace',
          repo_name: 'masc-mcp',
        },
        execution_links: {
          session_id: 'sess-next',
        },
      }),
      taskFixture({
        id: 'task-done',
        title: 'Completed queue item',
        status: 'done',
        goal_id: 'goal-next',
      }),
    ]

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    const queue = container.querySelector('[aria-label="Keeper active task queue"]')
    expect(queue?.textContent).toContain('ACTIVE QUEUE')
    expect(queue?.textContent).toContain('1 queued')
    expect(queue?.textContent).toContain('task-next')
    expect(queue?.textContent).toContain('Wire keeper queue context')
    expect(queue?.textContent).not.toContain('task-done')

    const queueButtons = Array.from(queue?.querySelectorAll('button') ?? [])
    expect(queueButtons.map(button => button.textContent)).toEqual([
      'Goal',
      'Task',
      'Git',
      'Telemetry',
      'Keeper',
    ])

    fireEvent.click(queueButtons.find(button => button.title === 'Task task-next')!)
    expect(window.location.hash).toBe('#workspace?section=planning&view=default&task=task-next')
  })
})

function buttonByText(container: HTMLElement, text: string): HTMLButtonElement {
  const button = Array.from(container.querySelectorAll('button'))
    .find(candidate => candidate.textContent === text)
  if (!(button instanceof HTMLButtonElement)) {
    throw new Error(`missing button: ${text}`)
  }
  return button
}

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

function goalFixture(partial: Partial<Goal> = {}): Goal {
  return {
    id: 'goal-runtime',
    horizon: 'short',
    title: 'Runtime goal',
    metric: 'green CI',
    target_value: '100%',
    priority: 1,
    status: 'active',
    phase: 'executing',
    created_at: '2026-05-13T00:00:00Z',
    updated_at: '2026-05-13T00:00:00Z',
    ...partial,
  }
}
