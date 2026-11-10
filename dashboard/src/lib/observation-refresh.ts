// Observation topics name authoritative read models. The transport publishes
// invalidations here; a mounted consumer reads only the models it uses.
import { readDashboardObservationTopic } from '../schemas/sse_event_generated'
import type { DashboardObservationTopic as GeneratedTopic } from '../schemas/sse_event_generated'

export type DashboardObservationTopic = Lowercase<GeneratedTopic['kind']>

export interface DashboardObservationChange {
  readonly topic: DashboardObservationTopic
  readonly keeperName?: string
  readonly operationId?: string
}

export interface DashboardObservationSelection {
  readonly topics: readonly DashboardObservationTopic[]
  readonly keeperName?: string
  readonly operationId?: string
}

type Observer = {
  readonly selection: DashboardObservationSelection
  readonly change: () => void
  readonly recovery: () => void
}

const observers = new Set<Observer>()

export function isDashboardObservationTopic(value: unknown): value is DashboardObservationTopic {
  try { readDashboardObservationTopic(value); return true } catch { return false }
}

export function publishDashboardObservationChange(change: DashboardObservationChange): void {
  for (const observer of [...observers]) {
    const { selection } = observer
    if (!selection.topics.includes(change.topic)) continue
    if (selection.keeperName !== undefined && change.keeperName !== undefined
      && selection.keeperName !== change.keeperName) continue
    if (selection.operationId !== undefined && change.operationId !== undefined
      && selection.operationId !== change.operationId) continue
    observer.change()
  }
}

/** Reconnect, lost replay, credentials or workspace authority changed. */
export function publishDashboardObservationRecovery(): void {
  for (const observer of [...observers]) observer.recovery()
}

export function subscribeDashboardObservation(
  selection: DashboardObservationSelection,
  change: () => void,
  recovery: () => void = change,
): () => void {
  const observer = { selection, change, recovery }
  observers.add(observer)
  return () => { observers.delete(observer) }
}

export interface ObservationRefreshOptions extends DashboardObservationSelection {
  /** Use false only when another mount effect owns the initial read. */
  readonly initial?: boolean
  readonly onError?: (error: unknown) => void
}

/** Subscribe before the first read. Invalidation during a read retains one
 * trailing read, including after recovery. Quiet streams never trigger HTTP.
 * Hidden consumers remember invalidation and read once when visible again. */
export function setupObservationRefresh(
  refresh: (signal: AbortSignal) => void | Promise<unknown>,
  options: ObservationRefreshOptions,
): () => void {
  let active = true
  let scheduled = false
  let inFlight = false
  let dirty = false
  let controller: AbortController | null = null

  const visible = () => typeof document.visibilityState !== 'string'
    || document.visibilityState === 'visible'

  const schedule = () => {
    if (!active || scheduled || inFlight || !dirty || !visible()) return
    scheduled = true
    queueMicrotask(() => { void drain() })
  }

  const invalidate = () => {
    if (!active) return
    dirty = true
    schedule()
  }

  const drain = async () => {
    scheduled = false
    if (!active || inFlight || !dirty || !visible()) return
    dirty = false
    inFlight = true
    controller = new AbortController()
    try {
      await refresh(controller.signal)
    } catch (error) {
      if (active && !controller.signal.aborted) {
        if (options.onError) options.onError(error)
        else console.warn('[observation] authoritative read failed', error)
      }
    } finally {
      controller = null
      inFlight = false
      schedule()
    }
  }

  const recover = () => {
    controller?.abort()
    invalidate()
  }
  const refreshWhenVisible = () => { if (visible()) invalidate() }
  const unsubscribe = subscribeDashboardObservation(options, invalidate, recover)
  window.addEventListener('focus', refreshWhenVisible)
  document.addEventListener('visibilitychange', refreshWhenVisible)
  if (options.initial !== false) invalidate()

  return () => {
    active = false
    dirty = false
    controller?.abort()
    unsubscribe()
    window.removeEventListener('focus', refreshWhenVisible)
    document.removeEventListener('visibilitychange', refreshWhenVisible)
  }
}
