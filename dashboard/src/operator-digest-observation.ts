import { batch } from '@preact/signals'
import { ApiRequestError, extractApiError, fetchOperatorDigest } from './api/core'
import { UI_REFRESH_TTL_MS } from './config/constants'
import {
  captureDashboardObservationOwner, dashboardObservationOwnerIsCurrent,
  dashboardObservationOwnerHasWorkspace, subscribeDashboardObservationOwnerChanges,
} from './lib/observation-read-owner'
import { subscribeDashboardObservation } from './lib/observation-refresh'
import { createReadRecovery } from './lib/read-recovery'
import { isRecord } from './lib/type-guards'
import { normalizeOperatorDigest } from './operator-normalizers'
import { operatorWorkspaceDigest, operatorDigestLoading, operatorDigestError, operatorDigestErrorStatus } from './operator-signals'
import { operatorDigestPublication, operatorDigestQuery, sameOperatorDigestQuery,
  type OperatorDigestQuery } from './operator-digest-contract'

interface Owner {
  readonly authority: ReturnType<typeof captureDashboardObservationOwner>
  readonly instance: string
  readonly recovery: ReturnType<typeof createReadRecovery>
  query: OperatorDigestQuery | null
  generation: number
  sequence: number
  displayRevision: number
  lastReadAt: number | null
  refused: boolean
  followup: Promise<void> | null
}
interface Flight { readonly owner: Owner; readonly controller: AbortController; promise: Promise<void> }
let owner: Owner | null = null
let flight: Flight | null = null
let mounted = 0
const current = (original: Owner) => owner === original && dashboardObservationOwnerIsCurrent(original.authority)

function retire() {
  const previous = flight
  flight = null
  previous?.controller.abort()
  owner?.recovery.dispose()
  owner = null
  batch(() => {
    operatorWorkspaceDigest.value = null
    operatorDigestLoading.value = false
    operatorDigestError.value = null
    operatorDigestErrorStatus.value = null
  })
}

function admittedOwner(): Owner | null {
  if (owner !== null && current(owner)) return owner
  retire()
  const authority = captureDashboardObservationOwner()
  if (!dashboardObservationOwnerHasWorkspace(authority)) return null
  owner = { authority, instance: authority.workspace.observerInstanceId, recovery: createReadRecovery(),
    query: null, generation: -1, sequence: -1, displayRevision: 0, lastReadAt: null, refused: false, followup: null }
  return owner
}

function installBody(raw: unknown, state: 'initializing' | 'ready' | 'error') {
  const diagnostics = isRecord(raw) && isRecord(raw.projection_diagnostics) ? raw.projection_diagnostics : null
  batch(() => {
    if (state !== 'initializing' || operatorWorkspaceDigest.peek() === null) {
      operatorWorkspaceDigest.value = normalizeOperatorDigest(raw)
    }
    operatorDigestLoading.value = false
    operatorDigestError.value = state === 'error'
      ? typeof diagnostics?.stale_reason === 'string' ? diagnostics.stale_reason : 'Operator Digest source read failed' : null
    operatorDigestErrorStatus.value = null
  })
}

/** Default broadcasts cannot replace another actor's pending confirmations. */
export function hydrateOperatorDigest(raw: unknown): boolean {
  const publication = operatorDigestPublication(raw)
  const original = admittedOwner()
  if (publication === null || original === null || publication.instance !== original.instance) return false
  if (publication.generation < original.generation
    || publication.generation === original.generation && publication.sequence <= original.sequence) return false
  original.generation = publication.generation
  original.sequence = publication.sequence
  if (original.query === null || !sameOperatorDigestQuery(original.query, publication.query)) {
    // Actual source invalidation owes at most one read after the active one.
    // Its completed observation remains useful during continuous input.
    if (publication.state !== 'initializing') void refreshOperatorWorkspaceDigest({ force: true })
    return true
  }
  original.displayRevision++
  original.lastReadAt = Date.now()
  original.recovery.succeeded()
  const previous = flight
  if (previous?.owner === original) { flight = null; previous.controller.abort() }
  installBody(raw, publication.state)
  return true
}

export async function refreshOperatorWorkspaceDigest(opts?: { force?: boolean }): Promise<void> {
  const original = admittedOwner()
  if (original === null || original.refused) return
  if (flight?.owner === original) {
    if (!opts?.force) return flight.promise
    if (original.followup === null) original.followup = flight.promise.then(async () => {
      original.followup = null
      if (current(original)) await refreshOperatorWorkspaceDigest({ force: true })
    })
    return original.followup
  }
  if (!opts?.force && original.lastReadAt !== null && Date.now() - original.lastReadAt < UI_REFRESH_TTL_MS) return
  const read: Flight = { owner: original, controller: new AbortController(), promise: Promise.resolve() }
  flight = read
  const revision = original.displayRevision
  original.recovery.started()
  operatorDigestLoading.value = true
  read.promise = (async () => {
    try {
      const raw = await fetchOperatorDigest({ targetType: 'workspace', signal: read.controller.signal })
      if (!current(original) || read.controller.signal.aborted || original.displayRevision !== revision) return
      const query = operatorDigestQuery(raw)
      if (!isRecord(raw) || raw.observer_instance_id !== original.instance || query === null
        || query.targetId !== null || query.includeWorkers !== null) {
        throw new Error('Operator Digest did not attest its captured workspace and query')
      }
      if (typeof raw.error === 'string') throw new Error(typeof raw.message === 'string' ? raw.message : raw.error)
      original.query = query
      const publication = operatorDigestPublication(raw)
      if (publication === null && ('digest_publication_generation' in raw || 'digest_publication_sequence' in raw
        || 'digest_observation_state' in raw)) throw new Error('Operator Digest publication metadata is invalid')
      const state = publication?.state ?? (raw.health === 'initializing' ? 'initializing' : 'ready')
      // A repeated HTTP ordering still carries this request's actual body.
      // A newer installed broadcast has already fenced it by displayRevision.
      installBody(raw, state)
      if (publication !== null && (publication.generation > original.generation
        || publication.generation === original.generation && publication.sequence > original.sequence)) {
        original.generation = publication.generation
        original.sequence = publication.sequence
      }
      original.lastReadAt = Date.now()
      if (state === 'initializing' && publication === null) original.recovery.waiting(() => { void refreshOperatorWorkspaceDigest({ force: true }) })
      else original.recovery.succeeded()
    } catch (cause) {
      if (!current(original) || read.controller.signal.aborted || original.displayRevision !== revision) return
      original.refused = cause instanceof ApiRequestError && (cause.status === 401 || cause.status === 403)
      const summary = extractApiError(cause, 'operator 다이제스트 로드 실패')
      operatorDigestError.value = summary.message
      operatorDigestErrorStatus.value = summary.status
      original.recovery.failed(() => { void refreshOperatorWorkspaceDigest({ force: true }) }, !original.refused)
    } finally {
      if (flight === read) { flight = null; operatorDigestLoading.value = false }
    }
  })()
  return read.promise
}

export function setupOperatorDigestObservation(): () => void {
  mounted++
  const replace = () => {
    const previous = owner
    const next = admittedOwner()
    if (next !== null && next !== previous) void refreshOperatorWorkspaceDigest({ force: true })
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
