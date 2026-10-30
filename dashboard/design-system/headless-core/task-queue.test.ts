// Pure TS unit tests for TaskQueue. No DOM.
import { describe, it, expect } from 'vitest'
import {
  createTaskQueueManager,
  type Task,
  type TaskDescriptor,
} from './task-queue'

let clock = 0
function nextTime(): string {
  clock += 1
  // ISO format with monotonic millisecond increment so localCompare is FIFO.
  return new Date(2026, 0, 1, 0, 0, 0, clock).toISOString()
}

function reset(): void {
  clock = 0
}

function task(id: string, patch: Partial<TaskDescriptor> = {}): TaskDescriptor {
  return {
    id,
    agentId: patch.agentId ?? 'a1',
    title: patch.title ?? `Task ${id}`,
    priority: patch.priority ?? 5,
    state: patch.state ?? 'queued',
    ...patch,
  }
}

describe('createTaskQueueManager — add / get', () => {
  it('add() inserts task and subscribers fire once', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    let fires = 0
    let captured: ReadonlyArray<Task> = []
    m.subscribe((s) => {
      fires += 1
      captured = s
    })
    m.add(task('t1'))
    expect(fires).toBe(1)
    expect(captured.map((t) => t.id)).toEqual(['t1'])
    expect(m.getAll().length).toBe(1)
  })

  it('add() is idempotent on duplicate id', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1'))
    m.add(task('t1', { title: 'Different title' }))
    expect(m.getAll().length).toBe(1)
    expect(m.getAll()[0]!.title).toBe('Task t1')
  })

  it('initialTasks seed via constructor', () => {
    reset()
    const m = createTaskQueueManager({
      now: nextTime,
      initialTasks: [task('a'), task('b')],
    })
    expect(m.getAll().map((t) => t.id)).toEqual(['a', 'b'])
  })
})

describe('createTaskQueueManager — update / state transitions', () => {
  it('update state: running → completed sets snapshot', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1', { state: 'running' }))
    let fired: Task | null = null
    m.subscribeTask('t1', (t) => {
      fired = t
    })
    m.update('t1', { state: 'completed', completedAt: '2026-01-01T00:00:01Z' })
    expect(fired).not.toBeNull()
    expect((fired as unknown as Task).state).toBe('completed')
  })

  it('announceStateChange: queued → running emits "started"', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1', { title: 'Build', state: 'queued' }))
    m.update('t1', { state: 'running' })
    const a = m.announceStateChange('t1', 'queued')
    expect(a.text).toBe('Build started')
    expect(a.assertive).toBe(false)
  })

  it('announceStateChange: running → failed is assertive with errorMessage', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1', { title: 'Deploy', state: 'running' }))
    m.update('t1', { state: 'failed', errorMessage: 'auth refused' })
    const a = m.announceStateChange('t1', 'running')
    expect(a.text).toBe('Deploy failed: auth refused')
    expect(a.assertive).toBe(true)
  })

  it('announceStateChange: running → paused / paused → running', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1', { title: 'Sync', state: 'running' }))
    m.update('t1', { state: 'paused' })
    expect(m.announceStateChange('t1', 'running').text).toBe('Sync paused')
    m.update('t1', { state: 'running' })
    expect(m.announceStateChange('t1', 'paused').text).toBe('Sync resumed')
  })

  it('announceStateChange: → queued is silent', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1', { title: 'X', state: 'running' }))
    // Forced reset: directly transition to queued (RFC retry case).
    m.update('t1', { state: 'queued' })
    expect(m.announceStateChange('t1', 'running').text).toBe('')
  })
})

describe('createTaskQueueManager — byPriority ordering', () => {
  it('priority desc, then FIFO at same priority', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('a', { priority: 5 })) // createdAt earliest among prio-5
    m.add(task('b', { priority: 10 })) // priority 10
    m.add(task('c', { priority: 5 })) // createdAt later than a
    const ord = m.byPriority().map((t) => t.id)
    expect(ord).toEqual(['b', 'a', 'c'])
  })

  it('running before queued at same priority', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('q1', { priority: 5, state: 'queued' }))
    m.add(task('r1', { priority: 5, state: 'running' }))
    const ord = m.byPriority().map((t) => t.id)
    expect(ord).toEqual(['r1', 'q1'])
  })

  it('reorder() override survives until next priority/state change', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('a', { priority: 10 }))
    m.add(task('b', { priority: 5 }))
    m.add(task('c', { priority: 1 }))
    expect(m.byPriority().map((t) => t.id)).toEqual(['a', 'b', 'c'])
    m.reorder(['c', 'a', 'b'])
    expect(m.byPriority().map((t) => t.id)).toEqual(['c', 'a', 'b'])
    // Update non-state, non-priority field — override survives.
    m.update('a', { description: 'note' })
    expect(m.byPriority().map((t) => t.id)).toEqual(['c', 'a', 'b'])
    // State change clears override.
    m.update('a', { state: 'running' })
    expect(m.byPriority().map((t) => t.id)).toEqual(['a', 'b', 'c'])
  })

  it('byPriority excludes terminal states', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('a', { state: 'completed' }))
    m.add(task('b', { state: 'running' }))
    m.add(task('c', { state: 'failed' }))
    expect(m.byPriority().map((t) => t.id)).toEqual(['b'])
  })
})

describe('createTaskQueueManager — query views', () => {
  it('byState filters', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('a', { state: 'running' }))
    m.add(task('b', { state: 'queued' }))
    m.add(task('c', { state: 'running' }))
    expect(m.byState('running').map((t) => t.id)).toEqual(['a', 'c'])
    expect(m.byState('queued').map((t) => t.id)).toEqual(['b'])
  })

  it('byAgent filters', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('a', { agentId: 'k1' }))
    m.add(task('b', { agentId: 'k2' }))
    m.add(task('c', { agentId: 'k1' }))
    expect(m.byAgent('k1').map((t) => t.id)).toEqual(['a', 'c'])
    expect(m.byAgent('k2').map((t) => t.id)).toEqual(['b'])
  })
})

describe('createTaskQueueManager — retention', () => {
  it('maxRetention evicts oldest terminal task; active never evicted', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime, maxRetention: 2 })
    m.add(task('c1', { state: 'completed' }))
    m.add(task('c2', { state: 'completed' }))
    m.add(task('a1', { state: 'running' }))
    // 3 tasks, 2 terminal, retention 2 → at limit, no evict yet.
    expect(m.getAll().length).toBe(3)
    m.add(task('c3', { state: 'completed' }))
    // 3 terminal > 2 → oldest terminal (c1) evicted.
    expect(m.getAll().map((t) => t.id)).toEqual(['c2', 'a1', 'c3'])
  })

  it('update to terminal triggers eviction', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime, maxRetention: 1 })
    m.add(task('c1', { state: 'completed' }))
    m.add(task('r1', { state: 'running' }))
    // 1 terminal at limit. Now flip r1 to completed → 2 terminal,
    // c1 (oldest) evicts.
    m.update('r1', { state: 'completed' })
    expect(m.getAll().map((t) => t.id)).toEqual(['r1'])
  })
})

describe('createTaskQueueManager — subscriptions', () => {
  it('subscribeTask isolates by id', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1'))
    m.add(task('t2'))
    let t1Fires = 0
    let t2Fires = 0
    m.subscribeTask('t1', () => {
      t1Fires += 1
    })
    m.subscribeTask('t2', () => {
      t2Fires += 1
    })
    m.update('t1', { state: 'running' })
    expect(t1Fires).toBe(1)
    expect(t2Fires).toBe(0)
  })

  it('100 sequential update() calls produce 100 emits (no batching)', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('t1', { state: 'running', progress: 0 }))
    let fires = 0
    m.subscribe(() => {
      fires += 1
    })
    for (let i = 1; i <= 100; i += 1) {
      m.update('t1', { progress: i })
    }
    expect(fires).toBe(100)
  })

  it('subscribe leak — unsubscribe stops fires', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    let fires = 0
    const dispose = m.subscribe(() => {
      fires += 1
    })
    m.add(task('t1'))
    expect(fires).toBe(1)
    dispose()
    m.add(task('t2'))
    expect(fires).toBe(1)
  })
})

describe('createTaskQueueManager — remove', () => {
  it('remove() drops task and clears reorder mention', () => {
    reset()
    const m = createTaskQueueManager({ now: nextTime })
    m.add(task('a'))
    m.add(task('b'))
    m.add(task('c'))
    m.reorder(['c', 'a', 'b'])
    m.remove('a')
    expect(m.getAll().map((t) => t.id)).toEqual(['b', 'c'])
    expect(m.byPriority().map((t) => t.id)).toEqual(['c', 'b'])
  })
})
