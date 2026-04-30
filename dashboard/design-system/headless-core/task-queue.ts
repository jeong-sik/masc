/**
 * TaskQueue — framework-agnostic queue manager for MASC tasks (RFC 0009).
 *
 * Mirrors MASC's task storage; never authors. Owns canonical task list,
 * answers priority/state/agent queries, and emits SR announcements with
 * the right urgency for each transition. Sister to Toast (RFC 0007) —
 * both are append-only event surfaces, but Task is structured + queryable
 * while Toast is ephemeral.
 *
 * MVP scope (RFC 0009 §3, §4, §5, §6, §7):
 *   - Five states: queued / running / paused / completed / failed
 *   - byPriority order: priority desc, running > paused > queued at same
 *     priority, FIFO within remainder
 *   - reorder(ids) explicit override; cleared on next priority/state change
 *   - announceStateChange(id, prev) emits text + assertive flag matching
 *     RFC §4 transition table; failed → assertive=true
 *   - maxRetention default 200; evicts oldest completed/failed only
 *
 * Out of scope (deferred per RFC 0009 §11):
 *   - Multi-assignee tasks
 *   - localStorage persistence of reorder override
 *   - Failed → queued retry as new task vs same id (caller decides)
 */

export type TaskState = 'queued' | 'running' | 'paused' | 'completed' | 'failed'

export interface TaskDescriptor {
  readonly id: string
  readonly agentId: string
  readonly title: string
  readonly description?: string
  readonly priority: number
  readonly state: TaskState
  readonly progress?: number
  readonly startedAt?: string
  readonly completedAt?: string
  readonly errorMessage?: string
}

export interface Task extends TaskDescriptor {
  readonly createdAt: string
}

export interface TaskQueueOptions {
  initialTasks?: ReadonlyArray<TaskDescriptor>
  maxRetention?: number
  /** Override creation timestamp generator (testing). */
  now?: () => string
}

export interface StateAnnouncement {
  readonly text: string
  readonly assertive: boolean
}

export interface TaskQueueManager {
  add(task: TaskDescriptor): void
  remove(id: string): void
  update(id: string, patch: Partial<Omit<TaskDescriptor, 'id'>>): void
  reorder(ids: ReadonlyArray<string>): void

  getAll(): ReadonlyArray<Task>
  byState(state: TaskState): ReadonlyArray<Task>
  byAgent(agentId: string): ReadonlyArray<Task>
  byPriority(): ReadonlyArray<Task>

  subscribe(listener: (tasks: ReadonlyArray<Task>) => void): () => void
  subscribeTask(id: string, listener: (task: Task) => void): () => void

  announceStateChange(id: string, prev: TaskState): StateAnnouncement
}

const DEFAULT_RETENTION = 200

function isActive(state: TaskState): boolean {
  return state === 'queued' || state === 'running' || state === 'paused'
}

function isTerminal(state: TaskState): boolean {
  return state === 'completed' || state === 'failed'
}

function activeStateRank(state: TaskState): number {
  if (state === 'running') return 0
  if (state === 'paused') return 1
  if (state === 'queued') return 2
  return 3
}

export function createTaskQueueManager(opts?: TaskQueueOptions): TaskQueueManager {
  const maxRetention = opts?.maxRetention ?? DEFAULT_RETENTION
  const now = opts?.now ?? (() => new Date().toISOString())

  const tasks = new Map<string, Task>()
  const insertionOrder: string[] = []
  let reorderOverride: ReadonlyArray<string> | null = null

  const listeners = new Set<(tasks: ReadonlyArray<Task>) => void>()
  const taskListeners = new Map<string, Set<(task: Task) => void>>()

  function snapshot(): ReadonlyArray<Task> {
    return Object.freeze(insertionOrder.map((id) => tasks.get(id)!).filter(Boolean))
  }

  function emit(): void {
    const s = snapshot()
    for (const l of listeners) l(s)
  }

  function emitTask(t: Task): void {
    const set = taskListeners.get(t.id)
    if (set === undefined) return
    for (const l of set) l(t)
  }

  function evictIfOverflow(): void {
    let nonActive = 0
    for (const t of tasks.values()) {
      if (isTerminal(t.state)) nonActive += 1
    }
    while (nonActive > maxRetention) {
      // Find oldest terminal task in insertion order.
      for (const id of insertionOrder) {
        const t = tasks.get(id)
        if (t !== undefined && isTerminal(t.state)) {
          tasks.delete(id)
          const idx = insertionOrder.indexOf(id)
          if (idx >= 0) insertionOrder.splice(idx, 1)
          break
        }
      }
      nonActive -= 1
    }
  }

  function add(descriptor: TaskDescriptor): void {
    if (tasks.has(descriptor.id)) return
    const t: Task = Object.freeze({
      ...descriptor,
      createdAt: now(),
    })
    tasks.set(t.id, t)
    insertionOrder.push(t.id)
    evictIfOverflow()
    emit()
    emitTask(t)
  }

  function remove(id: string): void {
    if (!tasks.has(id)) return
    tasks.delete(id)
    const idx = insertionOrder.indexOf(id)
    if (idx >= 0) insertionOrder.splice(idx, 1)
    if (reorderOverride !== null) {
      reorderOverride = reorderOverride.filter((x) => x !== id)
    }
    emit()
  }

  function update(id: string, patch: Partial<Omit<TaskDescriptor, 'id'>>): void {
    const cur = tasks.get(id)
    if (cur === undefined) return
    const next: Task = Object.freeze({ ...cur, ...patch })
    tasks.set(id, next)
    // Drop reorder override on priority or state change so byPriority
    // returns to natural ordering until consumer reorders again.
    if (
      ('priority' in patch && patch.priority !== cur.priority) ||
      ('state' in patch && patch.state !== cur.state)
    ) {
      reorderOverride = null
    }
    if ('state' in patch && isTerminal(next.state) && !isTerminal(cur.state)) {
      evictIfOverflow()
    }
    emit()
    emitTask(next)
  }

  function reorder(ids: ReadonlyArray<string>): void {
    // Validate: all ids exist and are active.
    for (const id of ids) {
      const t = tasks.get(id)
      if (t === undefined || !isActive(t.state)) return
    }
    reorderOverride = Object.freeze([...ids])
    emit()
  }

  function getAll(): ReadonlyArray<Task> {
    return snapshot()
  }

  function byState(state: TaskState): ReadonlyArray<Task> {
    return Object.freeze(snapshot().filter((t) => t.state === state))
  }

  function byAgent(agentId: string): ReadonlyArray<Task> {
    return Object.freeze(snapshot().filter((t) => t.agentId === agentId))
  }

  function byPriority(): ReadonlyArray<Task> {
    const active = snapshot().filter((t) => isActive(t.state))
    if (reorderOverride !== null) {
      const map = new Map(active.map((t) => [t.id, t]))
      const out: Task[] = []
      for (const id of reorderOverride) {
        const t = map.get(id)
        if (t !== undefined) out.push(t)
      }
      return Object.freeze(out)
    }
    return Object.freeze(
      [...active].sort((a, b) => {
        if (a.priority !== b.priority) return b.priority - a.priority
        const sa = activeStateRank(a.state)
        const sb = activeStateRank(b.state)
        if (sa !== sb) return sa - sb
        return a.createdAt.localeCompare(b.createdAt)
      }),
    )
  }

  function subscribe(listener: (tasks: ReadonlyArray<Task>) => void): () => void {
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  }

  function subscribeTask(id: string, listener: (task: Task) => void): () => void {
    let set = taskListeners.get(id)
    if (set === undefined) {
      set = new Set()
      taskListeners.set(id, set)
    }
    set.add(listener)
    return () => {
      set!.delete(listener)
      if (set!.size === 0) taskListeners.delete(id)
    }
  }

  function announceStateChange(id: string, prev: TaskState): StateAnnouncement {
    const cur = tasks.get(id)
    if (cur === undefined) {
      return Object.freeze({ text: '', assertive: false })
    }
    const next = cur.state
    if (next === prev) return Object.freeze({ text: '', assertive: false })

    if (next === 'queued') {
      return Object.freeze({ text: '', assertive: false })
    }
    if (next === 'running' && prev === 'paused') {
      return Object.freeze({ text: `${cur.title} resumed`, assertive: false })
    }
    if (next === 'running') {
      // queued → running OR direct ?→running (RFC §4 last row "skipping queued")
      return Object.freeze({ text: `${cur.title} started`, assertive: false })
    }
    if (next === 'paused' && prev === 'running') {
      return Object.freeze({ text: `${cur.title} paused`, assertive: false })
    }
    if (next === 'completed') {
      return Object.freeze({ text: `${cur.title} completed`, assertive: false })
    }
    if (next === 'failed') {
      const msg = cur.errorMessage !== undefined && cur.errorMessage.length > 0
        ? `${cur.title} failed: ${cur.errorMessage}`
        : `${cur.title} failed`
      return Object.freeze({ text: msg, assertive: true })
    }
    return Object.freeze({ text: '', assertive: false })
  }

  // Seed initial roster.
  if (opts?.initialTasks !== undefined) {
    for (const d of opts.initialTasks) add(d)
  }

  return {
    add,
    remove,
    update,
    reorder,
    getAll,
    byState,
    byAgent,
    byPriority,
    subscribe,
    subscribeTask,
    announceStateChange,
  }
}
