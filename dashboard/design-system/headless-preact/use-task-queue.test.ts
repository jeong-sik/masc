// @vitest-environment happy-dom
//
// Tests for headless-preact/use-task-queue. Verifies that hooks
// react to manager updates via Preact re-render cycle.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { createTaskQueueManager } from '../headless-core/task-queue'
import {
  useTask,
  useTaskQueue,
  useTasksByPriority,
  useTasksByState,
  useTasksForAgent,
} from './use-task-queue'

function flushEffects(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 16))
}

let container: HTMLElement
let mounted = 0

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  mounted = 0
})

afterEach(() => {
  render(null, container)
  container.remove()
})

describe('useTaskQueue', () => {
  it('reads initial snapshot synchronously on mount', async () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'first', priority: 1, state: 'queued' },
      ],
    })
    let captured: ReadonlyArray<{ id: string }> = []
    function Probe(): unknown {
      const { tasks } = useTaskQueue(manager)
      captured = tasks
      mounted += 1
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.map((t) => t.id)).toEqual(['t1'])
  })

  it('re-renders on add', async () => {
    const manager = createTaskQueueManager()
    let captured: ReadonlyArray<{ id: string }> = []
    function Probe(): unknown {
      const { tasks } = useTaskQueue(manager)
      captured = tasks
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    manager.add({ id: 't1', agentId: 'a', title: 'x', priority: 1, state: 'queued' })
    await flushEffects()
    expect(captured.map((t) => t.id)).toEqual(['t1'])
  })

  it('byState exposes manager.byState', async () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'r', priority: 1, state: 'running' },
        { id: 't2', agentId: 'a', title: 'q', priority: 1, state: 'queued' },
      ],
    })
    let api!: ReturnType<typeof useTaskQueue>
    function Probe(): unknown {
      api = useTaskQueue(manager)
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(api.byState('running').map((t) => t.id)).toEqual(['t1'])
    expect(api.byState('queued').map((t) => t.id)).toEqual(['t2'])
  })
})

describe('useTask', () => {
  it('returns undefined for unknown id (no throw)', async () => {
    const manager = createTaskQueueManager()
    let captured: { id: string } | undefined = { id: 'placeholder' }
    function Probe(): unknown {
      captured = useTask(manager, 'missing')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured).toBeUndefined()
  })

  it('re-renders only on per-task changes', async () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'one', priority: 1, state: 'queued' },
        { id: 't2', agentId: 'a', title: 'two', priority: 1, state: 'queued' },
      ],
    })
    let renders = 0
    let last: { state: string } | undefined
    function Probe(): unknown {
      renders += 1
      last = useTask(manager, 't1')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    const before = renders
    manager.update('t2', { state: 'running' })
    await flushEffects()
    expect(renders).toBe(before)
    manager.update('t1', { state: 'running' })
    await flushEffects()
    expect(last?.state).toBe('running')
    expect(renders).toBeGreaterThan(before)
  })
})

describe('useTasksForAgent', () => {
  it('filters to agentId and updates on add', async () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'alice', title: 'a1', priority: 1, state: 'queued' },
        { id: 't2', agentId: 'bob', title: 'b1', priority: 1, state: 'queued' },
      ],
    })
    let captured: ReadonlyArray<{ id: string }> = []
    function Probe(): unknown {
      captured = useTasksForAgent(manager, 'alice')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.map((t) => t.id)).toEqual(['t1'])
    manager.add({ id: 't3', agentId: 'alice', title: 'a2', priority: 1, state: 'queued' })
    await flushEffects()
    expect(captured.map((t) => t.id).sort()).toEqual(['t1', 't3'])
  })
})

describe('useTasksByState', () => {
  it('returns only matching state tasks and updates on transition', async () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'r', priority: 1, state: 'running' },
        { id: 't2', agentId: 'a', title: 'q', priority: 1, state: 'queued' },
      ],
    })
    let captured: ReadonlyArray<{ id: string }> = []
    function Probe(): unknown {
      captured = useTasksByState(manager, 'running')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.map((t) => t.id)).toEqual(['t1'])
    manager.update('t2', { state: 'running' })
    await flushEffects()
    expect(captured.map((t) => t.id).sort()).toEqual(['t1', 't2'])
  })
})

describe('useTasksByPriority', () => {
  it('returns priority-ordered tasks', async () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 'lo', agentId: 'a', title: 'l', priority: 1, state: 'queued' },
        { id: 'hi', agentId: 'a', title: 'h', priority: 5, state: 'queued' },
      ],
    })
    let captured: ReadonlyArray<{ id: string }> = []
    function Probe(): unknown {
      captured = useTasksByPriority(manager)
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.map((t) => t.id)).toEqual(['hi', 'lo'])
  })
})
