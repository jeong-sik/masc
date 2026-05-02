/**
 * run-activity-store - typed snapshot store for the IDE ACTIVITY pane.
 *
 * The live SSE bridge can append the same event shape later; the current
 * IDE mock seeds static events through this store so filtering, ordering, and
 * keeper grouping are no longer embedded in the renderer.
 */

import { signal } from '@preact/signals'

const DEFAULT_MAX_EVENTS = 200
const RUN_ACTIVITY_VERBS = [
  'flagged',
  'edited',
  'commented on',
  'approved',
  'noted',
  'suggested on',
  'committed',
  'refactored',
  'asked on',
] as const
const RUN_ACTIVITY_VERB_SET = new Set<string>(RUN_ACTIVITY_VERBS)

export type RunActivityVerb = (typeof RUN_ACTIVITY_VERBS)[number]

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
  readonly seed: (events: ReadonlyArray<unknown>) => void
  readonly append: (event: unknown) => boolean
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
  const maxEvents = normalizeMaxEvents(opts.maxEvents)
  const activeRunId = signal(initialRunId)
  const allEvents = signal<ReadonlyArray<RunActivityEvent>>([])
  const visibleEvents = signal<ReadonlyArray<RunActivityEvent>>([])
  const keepers = signal<ReadonlyArray<string>>([])

  const publish = (): void => {
    visibleEvents.value = allEvents.value
    keepers.value = sortedKeepers(allEvents.value)
  }

  const seed = (events: ReadonlyArray<unknown>): void => {
    allEvents.value = events
      .filter((event): event is RunActivityEvent =>
        validEventForRun(event, activeRunId.value),
      )
      .sort(compareEvents)
      .slice(0, maxEvents)
    publish()
  }

  const append = (event: unknown): boolean => {
    if (!validEventForRun(event, activeRunId.value)) return false
    allEvents.value = insertEvent(allEvents.value, event, maxEvents)
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

type UnknownRecord = Record<string, unknown>

function normalizeMaxEvents(value: number | undefined): number {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) return value
  return DEFAULT_MAX_EVENTS
}

function validEventForRun(event: unknown, runId: string): event is RunActivityEvent {
  if (!isRecord(event)) return false
  if (event.run_id !== runId) return false
  if (!hasNonEmptyString(event, 'id')) return false
  if (!hasNonEmptyString(event, 'keeper_id')) return false
  if (!hasNonEmptyString(event, 'target')) return false
  if (!isRunActivityVerb(event.verb)) return false
  if (event.detail !== undefined && typeof event.detail !== 'string') return false
  return Number.isFinite(event.timestamp_ms)
}

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function hasNonEmptyString(record: UnknownRecord, key: string): boolean {
  const value = record[key]
  return typeof value === 'string' && value.trim() !== ''
}

function isRunActivityVerb(value: unknown): value is RunActivityVerb {
  return typeof value === 'string' && RUN_ACTIVITY_VERB_SET.has(value)
}

function insertEvent(
  events: ReadonlyArray<RunActivityEvent>,
  event: RunActivityEvent,
  maxEvents: number,
): ReadonlyArray<RunActivityEvent> {
  const next = [...events]
  const index = next.findIndex(existing => compareEvents(event, existing) < 0)
  if (index === -1) next.push(event)
  else next.splice(index, 0, event)
  return next.slice(0, maxEvents)
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
