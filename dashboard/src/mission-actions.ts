import { batch } from '@preact/signals'
import { ApiRequestError } from './api/core'
import { fetchDashboardMission } from './api/dashboard-mission'
import {
  captureDashboardObservationOwner,
  dashboardObservationOwnerIsCurrent,
  dashboardObservationOwnerHasWorkspace,
  subscribeDashboardObservationOwnerChanges,
} from './lib/observation-read-owner'
import { errorMessageOr } from './lib/format-string'
import { isRecord } from './lib/type-guards'
import { createReadRecovery } from './lib/read-recovery'
import { subscribeDashboardObservation } from './lib/observation-refresh'
import { missionSnapshot, missionLoading, missionError, missionInitializing } from './mission-signals'
import { normalizeMission } from './mission-normalizers'
import { missionPublication } from './mission-observation-contract'

type ReadOwner = ReturnType<typeof captureDashboardObservationOwner>
interface Owner {
  readonly authority: ReadOwner
  readonly instance: string
  readonly recovery: ReturnType<typeof createReadRecovery>
  generation: number
  sequence: number
  revision: number
  lastReadAt: number | null
  refused: boolean
}
interface Flight {
  readonly owner: Owner
  readonly controller: AbortController
  promise: Promise<void>
}
let owner: Owner | null = null
let flight: Flight | null = null
let mounted = 0
const MISSION_TTL_MS = 3_000

function current(original: Owner): boolean {
  return owner === original && dashboardObservationOwnerIsCurrent(original.authority)
}

function retire(): void {
  const previous = flight
  flight = null
  previous?.controller.abort()
  owner?.recovery.dispose()
  owner = null
  batch(() => {
    missionSnapshot.value = null
    missionLoading.value = false
    missionInitializing.value = false
    missionError.value = null
  })
}

function admittedOwner(): Owner | null {
  if (owner !== null && current(owner)) return owner
  retire()
  const authority = captureDashboardObservationOwner()
  if (!dashboardObservationOwnerHasWorkspace(authority)) return null
  owner = { authority, instance: authority.workspace.observerInstanceId,
    recovery: createReadRecovery(), generation: -1, sequence: -1, revision: 0, lastReadAt: null, refused: false }
  return owner
}

/** Apply the canonical body itself. Its producer owns initializing/error debt. */
export function hydrateMissionSnapshot(raw: unknown): boolean {
  const publication = missionPublication(raw)
  const original = admittedOwner()
  if (publication === null || original === null
    || publication.observer_instance_id !== original.instance) return false
  const generation = publication.mission_publication_generation
  const sequence = publication.mission_publication_sequence
  if (generation < original.generation || generation === original.generation && sequence <= original.sequence) return false
  original.generation = generation
  original.sequence = sequence
  original.revision++
  original.lastReadAt = Date.now()
  original.recovery.succeeded()
  const previous = flight
  if (previous?.owner === original) { flight = null; previous.controller.abort() }
  const state = publication.mission_observation_state
  const diagnostics = isRecord(raw) && isRecord(raw.projection_diagnostics) ? raw.projection_diagnostics : null
  batch(() => {
    if (state !== 'initializing' || missionSnapshot.peek() === null) missionSnapshot.value = normalizeMission(raw)
    missionLoading.value = false
    missionInitializing.value = state === 'initializing'
    missionError.value = state === 'error'
      ? typeof diagnostics?.stale_reason === 'string' ? diagnostics.stale_reason : 'Mission source read failed'
      : null
  })
  return true
}

export async function refreshMissionSnapshot(opts?: { force?: boolean }): Promise<void> {
  const original = admittedOwner()
  if (original === null || original.refused) return
  if (flight?.owner === original) return flight.promise
  if (!opts?.force && original.lastReadAt !== null && Date.now() - original.lastReadAt < MISSION_TTL_MS) return
  const read: Flight = { owner: original, controller: new AbortController(), promise: Promise.resolve() }
  flight = read
  const revision = original.revision
  original.recovery.started()
  missionLoading.value = true
  const retry = () => { void refreshMissionSnapshot({ force: true }) }
  read.promise = (async () => {
    try {
      const raw = await fetchDashboardMission({ signal: read.controller.signal })
      if (!current(original) || read.controller.signal.aborted || revision !== original.revision) return
      if (!isRecord(raw) || raw.observer_instance_id !== original.instance) {
        throw new Error('Mission response did not attest its original workspace')
      }
      if (missionPublication(raw) !== null) { hydrateMissionSnapshot(raw); return }
      if ('mission_publication_generation' in raw || 'mission_publication_sequence' in raw
        || 'mission_observation_state' in raw) throw new Error('Mission publication metadata is invalid')
      // Actor-local HTTP has no canonical ordering. A newer canonical body
      // fences this whole read, including initializing and failure outcomes.
      const normalized = normalizeMission(raw)
      const initializing = normalized.summary.workspace_health === 'initializing'
      batch(() => {
        if (!initializing || missionSnapshot.peek() === null) missionSnapshot.value = normalized
        missionInitializing.value = initializing
        missionError.value = null
      })
      original.lastReadAt = Date.now()
      if (initializing) original.recovery.waiting(retry)
      else original.recovery.succeeded()
    } catch (cause) {
      if (!current(original) || read.controller.signal.aborted || revision !== original.revision) return
      original.refused = cause instanceof ApiRequestError && (cause.status === 401 || cause.status === 403)
      missionError.value = errorMessageOr(cause, 'Failed to load mission snapshot')
      original.recovery.failed(retry, !original.refused)
    } finally {
      if (flight === read) { flight = null; missionLoading.value = false }
    }
  })()
  return read.promise
}

/** App lifetime, with one initial read per actual credential/workspace owner. */
export function setupMissionObservation(): () => void {
  mounted++
  const replace = () => {
    const previous = owner
    const next = admittedOwner()
    if (next !== null && next !== previous) void refreshMissionSnapshot({ force: true })
  }
  const recover = () => { admittedOwner()?.recovery.recover() }
  const unsubscribeOwner = subscribeDashboardObservationOwnerChanges(replace)
  const unsubscribeRecovery = subscribeDashboardObservation({ topics: [] }, () => {}, recover)
  window.addEventListener('focus', recover)
  window.addEventListener('online', recover)
  replace()
  let active = true
  return () => {
    if (!active) return
    active = false
    unsubscribeOwner(); unsubscribeRecovery()
    window.removeEventListener('focus', recover)
    window.removeEventListener('online', recover)
    if (--mounted === 0) retire()
  }
}
