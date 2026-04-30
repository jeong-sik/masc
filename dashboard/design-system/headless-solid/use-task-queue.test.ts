// @vitest-environment happy-dom
//
// Tests for headless-solid/use-task-queue. Mirrors the Preact adapter
// scenario coverage. Solid-specific differences:
//   - Hooks run inside createRoot to register cleanup correctly.
//   - Returned accessors are functions; read by calling them.
//   - createEffect runs once initially, then on signal changes after a
//     microtask flush. Tests `await Promise.resolve()` to drain the
//     queue between assertions.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createComputed, createRoot } from 'solid-js'
import { createTaskQueueManager } from '../headless-core/task-queue'
import {
  useTask,
  useTaskQueue,
  useTasksByPriority,
  useTasksByState,
  useTasksForAgent,
} from './use-task-queue'

let dispose: (() => void) | undefined

beforeEach(() => {
  dispose = undefined
})

afterEach(() => {
  dispose?.()
})

function withRoot<T>(fn: () => T): T {
  return createRoot((d) => {
    dispose = d
    return fn()
  })
}

/** Drain Solid's microtask-scheduled createEffect queue. */
function flush(): Promise<void> {
  return Promise.resolve()
}

describe('useTaskQueue', () => {
  it('reads initial snapshot synchronously', () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'first', priority: 1, state: 'queued' },
      ],
    })
    const { tasks } = withRoot(() => useTaskQueue(manager))
    expect(tasks().map((t) => t.id)).toEqual(['t1'])
  })

  it('accessor reflects manager.add', () => {
    const manager = createTaskQueueManager()
    const { tasks } = withRoot(() => useTaskQueue(manager))
    manager.add({ id: 't1', agentId: 'a', title: 'x', priority: 1, state: 'queued' })
    expect(tasks().map((t) => t.id)).toEqual(['t1'])
  })

  it('byState exposes manager.byState directly', () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'r', priority: 1, state: 'running' },
        { id: 't2', agentId: 'a', title: 'q', priority: 1, state: 'queued' },
      ],
    })
    const api = withRoot(() => useTaskQueue(manager))
    expect(api.byState('running').map((t) => t.id)).toEqual(['t1'])
    expect(api.byState('queued').map((t) => t.id)).toEqual(['t2'])
  })

  it('createEffect re-runs on signal update', async () => {
    const manager = createTaskQueueManager()
    let runs = 0
    let last: ReadonlyArray<{ id: string }> = []
    withRoot(() => {
      const { tasks } = useTaskQueue(manager)
      createComputed(() => {
        last = tasks()
        runs += 1
      })
    })
    await flush()
    expect(runs).toBe(1)
    manager.add({ id: 't1', agentId: 'a', title: 'x', priority: 1, state: 'queued' })
    await flush()
    expect(runs).toBe(2)
    expect(last.map((t) => t.id)).toEqual(['t1'])
  })
})

describe('useTask', () => {
  it('returns undefined for unknown id (no throw)', () => {
    const manager = createTaskQueueManager()
    const task = withRoot(() => useTask(manager, 'missing'))
    expect(task()).toBeUndefined()
  })

  it('updates only when its task changes', async () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'one', priority: 1, state: 'queued' },
        { id: 't2', agentId: 'a', title: 'two', priority: 1, state: 'queued' },
      ],
    })
    let runs = 0
    let last: { state: string } | undefined
    withRoot(() => {
      const task = useTask(manager, 't1')
      createComputed(() => {
        last = task()
        runs += 1
      })
    })
    await flush()
    const before = runs
    manager.update('t2', { state: 'running' })
    await flush()
    expect(runs).toBe(before)
    manager.update('t1', { state: 'running' })
    await flush()
    expect(last?.state).toBe('running')
    expect(runs).toBeGreaterThan(before)
  })
})

describe('useTasksForAgent', () => {
  it('filters to agentId and refreshes on add', () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'alice', title: 'a1', priority: 1, state: 'queued' },
        { id: 't2', agentId: 'bob', title: 'b1', priority: 1, state: 'queued' },
      ],
    })
    const tasks = withRoot(() => useTasksForAgent(manager, 'alice'))
    expect(tasks().map((t) => t.id)).toEqual(['t1'])
    manager.add({ id: 't3', agentId: 'alice', title: 'a2', priority: 1, state: 'queued' })
    expect(tasks().map((t) => t.id).sort()).toEqual(['t1', 't3'])
  })
})

describe('useTasksByState', () => {
  it('refreshes on transition into target state', () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 't1', agentId: 'a', title: 'r', priority: 1, state: 'running' },
        { id: 't2', agentId: 'a', title: 'q', priority: 1, state: 'queued' },
      ],
    })
    const tasks = withRoot(() => useTasksByState(manager, 'running'))
    expect(tasks().map((t) => t.id)).toEqual(['t1'])
    manager.update('t2', { state: 'running' })
    expect(tasks().map((t) => t.id).sort()).toEqual(['t1', 't2'])
  })
})

describe('useTasksByPriority', () => {
  it('returns priority-ordered tasks', () => {
    const manager = createTaskQueueManager({
      initialTasks: [
        { id: 'lo', agentId: 'a', title: 'l', priority: 1, state: 'queued' },
        { id: 'hi', agentId: 'a', title: 'h', priority: 5, state: 'queued' },
      ],
    })
    const tasks = withRoot(() => useTasksByPriority(manager))
    expect(tasks().map((t) => t.id)).toEqual(['hi', 'lo'])
  })
})

describe('subscribe disposal', () => {
  it('createRoot dispose removes manager subscription', async () => {
    const manager = createTaskQueueManager()
    let runs = 0
    const localDispose = createRoot((d) => {
      const { tasks } = useTaskQueue(manager)
      createComputed(() => {
        void tasks()
        runs += 1
      })
      return d
    })
    await flush()
    expect(runs).toBe(1)
    manager.add({ id: 't1', agentId: 'a', title: 'x', priority: 1, state: 'queued' })
    await flush()
    expect(runs).toBe(2)
    localDispose()
    manager.add({ id: 't2', agentId: 'a', title: 'y', priority: 1, state: 'queued' })
    await flush()
    expect(runs).toBe(2)
  })
})
