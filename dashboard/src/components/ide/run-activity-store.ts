/**
 * run-activity-store - typed snapshot store for the IDE ACTIVITY pane.
 *
 * The live SSE bridge can append the same event shape later; the current
 * IDE mock seeds static events through this store so filtering, ordering, and
 * keeper grouping are no longer embedded in the renderer.
 */

import { signal } from '@preact/signals'

export type RunActivityVerb =
  | 'flagged'
  | 'edited'
  | 'commented on'
  | 'approved'
  | 'noted'
  | 'suggested on'
  | 'committed'
  | 'refactored'
  | 'asked on'

export interface RunActivityEvent {
  readonly id: string
  readonly run_id: string
  readonly keeper_id: string
  readonly verb: RunActivityVerb
  readonly target: string
  readonly timestamp_ms: number
  readonly detail?: string
}

export interface RunActivityStore {
  readonly runId: () => string
  readonly seed: (events: ReadonlyArray<RunActivityEvent>) => void
  readonly append: (event: RunActivityEvent) => boolean
  readonly events: () => ReadonlyArray<RunActivityEvent>
  readonly eventsForKeeper: (keeperId: string) => ReadonlyArray<RunActivityEvent>
  readonly knownKeepers: () => ReadonlyArray<string>
  readonly reset: (runId?: string) => void
  readonly subscribe: (listener: () => void) => () => void
}

export function createRunActivityStore(
  initialRunId: string,
  opts: { readonly maxEvents?: number } = {},
): RunActivityStore {
  const maxEvents = opts.maxEvents ?? 200
  const activeRunId = signal(initialRunId)
  const allEvents = signal<ReadonlyArray<RunActivityEvent>>([])
  const visibleEvents = signal<ReadonlyArray<RunActivityEvent>>([])
  const keepers = signal<ReadonlyArray<string>>([])

  const publish = (): void => {
    const visible = allEvents.value
      .filter(event => validEventForRun(event, activeRunId.value))
      .slice()
      .sort(compareEvents)
      .slice(0, maxEvents)
    visibleEvents.value = visible
    keepers.value = sortedKeepers(visible)
  }

  const seed = (events: ReadonlyArray<RunActivityEvent>): void => {
    allEvents.value = [...events]
    publish()
  }

  const append = (event: RunActivityEvent): boolean => {
    if (!validEventForRun(event, activeRunId.value)) return false
    allEvents.value = [...allEvents.value, event]
    publish()
    return true
  }

  const eventsForKeeper = (keeperId: string): ReadonlyArray<RunActivityEvent> =>
    visibleEvents.value.filter(event => event.keeper_id === keeperId)

  const reset = (runId?: string): void => {
    if (runId !== undefined) activeRunId.value = runId
    allEvents.value = []
    publish()
  }

  const subscribe = (listener: () => void): (() => void) => {
    let sawInitialSnapshot = false
    const unsubscribe = visibleEvents.subscribe(() => {
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        return
      }
      listener()
    })
    return unsubscribe
  }

  return {
    runId: () => activeRunId.value,
    seed,
    append,
    events: () => visibleEvents.value,
    eventsForKeeper,
    knownKeepers: () => keepers.value,
    reset,
    subscribe,
  }
}

function validEventForRun(event: RunActivityEvent, runId: string): boolean {
  if (event.run_id !== runId) return false
  if (event.id.trim() === '') return false
  if (event.keeper_id.trim() === '') return false
  if (event.target.trim() === '') return false
  return Number.isFinite(event.timestamp_ms)
}

function compareEvents(a: RunActivityEvent, b: RunActivityEvent): number {
  if (a.timestamp_ms !== b.timestamp_ms) return b.timestamp_ms - a.timestamp_ms
  return a.id.localeCompare(b.id)
}

function sortedKeepers(events: ReadonlyArray<RunActivityEvent>): ReadonlyArray<string> {
  const ids = new Set<string>()
  for (const event of events) ids.add(event.keeper_id)
  return [...ids].sort()
}
