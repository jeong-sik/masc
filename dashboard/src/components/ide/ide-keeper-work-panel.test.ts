import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { IdeKeeperWorkPanel, keeperWorkSummary } from './ide-keeper-work-panel'
import { keepers, tasks } from '../../store'
import { fleetCompositeSnapshot } from '../../composite-signals'
import type { Keeper, Task } from '../../types'
import type {
  FleetCompositeSnapshot,
  KeeperCompositeSnapshot,
} from '../../api/schemas/keeper-composite'

describe('IdeKeeperWorkPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
  })

  afterEach(() => {
    render(null, container)
    keepers.value = []
    tasks.value = []
    fleetCompositeSnapshot.value = null
    window.location.hash = ''
  })

  it('summarizes the selected keeper current task and terminal reason', () => {
    keepers.value = [keeperFixture()]
    tasks.value = [taskFixture()]

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    expect(container.textContent).toContain('KEEPER WORK')
    expect(container.textContent).toContain('task-151')
    expect(container.textContent).toContain('Fix codex runtime config')
    expect(container.textContent).toContain('provider_runtime_error')
    expect(container.textContent).toContain('inspect_provider_runtime_cause')
    expect(container.textContent).toContain('masc_claim_next')
  })

  it('renders live-turn fields from the composite snapshot SSOT', () => {
    keepers.value = [keeperFixture()]
    fleetCompositeSnapshot.value = fleetFixture([
      compositeFixture({
        keeper: 'sangsu',
        live_turn: {
          turn_id: 7,
          started_at: 1,
          last_progress_at: 2,
          last_progress_kind: 'tool',
          selected_model: 'claude-live-model',
          active_tool_count: 3,
        },
        last_skip: { ts: 9, reasons: ['idle_budget'] },
        turn_attempt: { turn_id: 7, attempts: 2, first_started_at: 1 },
        board_cursor: { ts: 5, post_id: 'post-42' },
      }),
    ])

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    // The store Keeper type carries none of these fields, so their
    // presence proves the panel sources the live-turn state from the
    // composite snapshot rather than re-deriving it from the store.
    expect(container.textContent).toContain('claude-live-model')
    expect(container.textContent).toContain('idle_budget')
    expect(container.textContent).toContain('post-42')
  })

  it('omits the live-turn strip when no composite snapshot resolves', () => {
    keepers.value = [keeperFixture()]
    fleetCompositeSnapshot.value = null

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    expect(container.querySelector('[aria-label="Keeper live turn"]')).toBeNull()
    expect(container.textContent).not.toContain('claude-live-model')
  })

  it('matches keeper-agent task assignees to the canonical keeper name', () => {
    const summary = keeperWorkSummary(
      'sangsu',
      [keeperFixture()],
      [taskFixture({ assignee: 'keeper-sangsu-agent' })],
    )

    expect(summary.currentTaskId).toBe('task-151')
    expect(summary.currentTask?.title).toBe('Fix codex runtime config')
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

  it('links the current task to git, telemetry, and keeper context', () => {
    keepers.value = [keeperFixture()]
    tasks.value = [taskFixture({

      execution_links: {
        session_id: 'sess-151',
        operation_id: 'op-151',
      },
    })]

    render(h(IdeKeeperWorkPanel, { keeperName: 'sangsu' }), container)

    const taskLinks = Array.from(
      container.querySelectorAll<HTMLButtonElement>('.ide-keeper-work-card .ide-keeper-work-links button'),
    )
    expect(taskLinks.every(link => link.classList.contains('v2-ide-action'))).toBe(true)
    expect(container.querySelector('.ide-keeper-work-card .ide-keeper-work-route-count')?.textContent)
      .toBe('CTX 3')
    expect(taskLinks.map(link => link.textContent)).toEqual([
      'Task',
      'Telemetry',
      'Keeper',
    ])
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
      taskFixture(),
      taskFixture({
        id: 'task-next',
        title: 'Wire keeper queue context',
        status: 'in_progress',

        execution_links: {
          session_id: 'sess-next',
        },
      }),
      taskFixture({
        id: 'task-done',
        title: 'Completed queue item',
        status: 'done',

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
      'Task',
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

function compositeFixture(
  overrides: Partial<KeeperCompositeSnapshot> = {},
): KeeperCompositeSnapshot {
  return {
    correlation_id: 'corr-sangsu',
    run_id: 'run-1',
    ts: 1_000_000,
    phase: 'running',
    turn_phase: 'executing',
    decision: { stage: 'undecided' },
    runtime: { state: 'active' },
    compaction: { stage: 'accumulating' },
    measurement: { captured: false },
    invariants: {
      phase_turn_alignment: true,
      no_runtime_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    fsm_guard_violation_breakdown: [],
    is_live: true,
    last_outcome: null,
    recommended_actions: [],
    ...overrides,
  }
}

function fleetFixture(snapshots: KeeperCompositeSnapshot[]): FleetCompositeSnapshot {
  return { generated_at: 1_000_000, count: snapshots.length, snapshots }
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
        code: 'provider_runtime_error',
        summary: 'provider runtime failed before the turn completed',
        next_action: 'inspect_provider_runtime_cause',
      },
    },
    recent_output_preview: 'provider runtime failure',
    recent_tool_names: ['masc_claim_next', 'masc_board_list'],
  } as Keeper
}

function taskFixture(partial: Partial<Task> = {}): Task {
  return {
    id: 'task-151',
    title: 'Fix codex runtime config',
    status: 'claimed',
    assignee: 'sangsu',
    ...partial,
  }
}
