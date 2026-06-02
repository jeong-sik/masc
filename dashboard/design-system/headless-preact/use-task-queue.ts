/**
 * useTaskQueue — Preact adapter over headless-core/TaskQueueManager
 * (RFC 0009 §3.3).
 *
 * Hooks for whole-snapshot, per-task, and per-agent subscriptions.
 * The manager is provided externally so multiple surfaces (rail,
 * keeper card, activity feed) share one canonical task list.
 */

import { useEffect, useMemo, useState } from 'preact/hooks'
import type {
  Task,
  TaskQueueManager,
  TaskState,
} from '../headless-core/task-queue'

export function useTaskQueue(manager: TaskQueueManager): {
  readonly tasks: ReadonlyArray<Task>
  readonly byState: (state: TaskState) => ReadonlyArray<Task>
} {
  const [tasks, setTasks] = useState<ReadonlyArray<Task>>(() => manager.getAll())
  useEffect(() => {
    setTasks(manager.getAll())
    const dispose = manager.subscribe((s) => setTasks(s))
    return dispose
  }, [manager])
  const api = useMemo(
    () => ({
      tasks,
      byState: (state: TaskState) => manager.byState(state),
    }),
    [manager, tasks],
  )
  return api
}

export function useTask(
  manager: TaskQueueManager,
  id: string,
): Task | undefined {
  const initial = useMemo(
    () => manager.getAll().find((t) => t.id === id),
    [manager, id],
  )
  const [task, setTask] = useState<Task | undefined>(initial)
  useEffect(() => {
    setTask(manager.getAll().find((t) => t.id === id))
    const dispose = manager.subscribeTask(id, (t) => setTask(t))
    return dispose
  }, [manager, id])
  return task
}

export function useTasksForAgent(
  manager: TaskQueueManager,
  agentId: string,
): ReadonlyArray<Task> {
  const [tasks, setTasks] = useState<ReadonlyArray<Task>>(() =>
    manager.byAgent(agentId),
  )
  useEffect(() => {
    setTasks(manager.byAgent(agentId))
    const dispose = manager.subscribe(() => setTasks(manager.byAgent(agentId)))
    return dispose
  }, [manager, agentId])
  return tasks
}

export function useTasksByState(
  manager: TaskQueueManager,
  state: TaskState,
): ReadonlyArray<Task> {
  const [tasks, setTasks] = useState<ReadonlyArray<Task>>(() =>
    manager.byState(state),
  )
  useEffect(() => {
    setTasks(manager.byState(state))
    const dispose = manager.subscribe(() => setTasks(manager.byState(state)))
    return dispose
  }, [manager, state])
  return tasks
}

export function useTasksByPriority(
  manager: TaskQueueManager,
): ReadonlyArray<Task> {
  const [tasks, setTasks] = useState<ReadonlyArray<Task>>(() =>
    manager.byPriority(),
  )
  useEffect(() => {
    setTasks(manager.byPriority())
    const dispose = manager.subscribe(() => setTasks(manager.byPriority()))
    return dispose
  }, [manager])
  return tasks
}
