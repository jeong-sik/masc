/**
 * useTaskQueue — SolidJS adapter over headless-core/TaskQueueManager
 * (RFC 0009 §3.3, RFC 0017 PoC).
 *
 * Mirror of headless-preact/use-task-queue.ts. Exposes Solid accessors
 * (Accessor<T>) instead of values; consumers call `tasks()` rather than
 * reading `tasks` directly. This is Solid's convention — readers run
 * inside reactive scopes and re-execute when the underlying Signal
 * updates.
 *
 * The same TaskQueueManager instance is consumed unchanged. Subscribing
 * via manager.subscribe() bridges the headless-core's plain callback
 * surface into Solid's signal graph: the listener mutates a Signal,
 * and any reactive scope reading the accessor re-runs.
 */

import {
  createMemo,
  createSignal,
  onCleanup,
  type Accessor,
} from 'solid-js'
import type {
  Task,
  TaskQueueManager,
  TaskState,
} from '../headless-core/task-queue'

export function useTaskQueue(manager: TaskQueueManager): {
  readonly tasks: Accessor<ReadonlyArray<Task>>
  readonly byState: (state: TaskState) => ReadonlyArray<Task>
} {
  const [tasks, setTasks] = createSignal<ReadonlyArray<Task>>(manager.getAll())
  const dispose = manager.subscribe((s) => setTasks(s))
  onCleanup(dispose)
  return {
    tasks,
    byState: (state: TaskState) => manager.byState(state),
  }
}

export function useTask(
  manager: TaskQueueManager,
  id: string,
): Accessor<Task | undefined> {
  const initial = manager.getAll().find((t) => t.id === id)
  const [task, setTask] = createSignal<Task | undefined>(initial)
  const dispose = manager.subscribeTask(id, (t) => setTask(() => t))
  onCleanup(dispose)
  return task
}

export function useTasksForAgent(
  manager: TaskQueueManager,
  agentId: string,
): Accessor<ReadonlyArray<Task>> {
  const [tasks, setTasks] = createSignal<ReadonlyArray<Task>>(
    manager.byAgent(agentId),
  )
  const dispose = manager.subscribe(() => setTasks(manager.byAgent(agentId)))
  onCleanup(dispose)
  return tasks
}

export function useTasksByState(
  manager: TaskQueueManager,
  state: TaskState,
): Accessor<ReadonlyArray<Task>> {
  const [tasks, setTasks] = createSignal<ReadonlyArray<Task>>(
    manager.byState(state),
  )
  const dispose = manager.subscribe(() => setTasks(manager.byState(state)))
  onCleanup(dispose)
  return tasks
}

export function useTasksByPriority(
  manager: TaskQueueManager,
): Accessor<ReadonlyArray<Task>> {
  const [tasks, setTasks] = createSignal<ReadonlyArray<Task>>(manager.byPriority())
  const dispose = manager.subscribe(() => setTasks(manager.byPriority()))
  onCleanup(dispose)
  return tasks
}

/**
 * Memoized priority view — re-derives only when the underlying
 * snapshot Signal updates. Preferred when the result feeds into
 * many reactive scopes that would otherwise each re-call byPriority().
 */
export function useTasksByPriorityMemo(
  manager: TaskQueueManager,
): Accessor<ReadonlyArray<Task>> {
  const { tasks } = useTaskQueue(manager)
  return createMemo(() => {
    void tasks()
    return manager.byPriority()
  })
}
