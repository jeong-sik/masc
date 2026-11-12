import { batch } from '@preact/signals'
import { ApiRequestError, extractApiError, fetchOperatorSnapshot } from './api/core'
import { UI_REFRESH_TTL_MS } from './config/constants'
import { captureDashboardObservationOwner, dashboardObservationOwnerHasWorkspace,
  dashboardObservationOwnerIsCurrent, subscribeDashboardObservationOwnerChanges } from './lib/observation-read-owner'
import { subscribeDashboardObservation } from './lib/observation-refresh'
import { createReadRecovery } from './lib/read-recovery'
import { projectionReadOutcome, type ProjectionReadOutcome } from './lib/projection-read-outcome'
import { isRecord } from './lib/type-guards'
import { normalizeOperatorSnapshot } from './operator-normalizers'
import { operatorError, operatorErrorStatus, operatorLoading } from './operator-signals'
import { clearOperatorSnapshot, publishOperatorSnapshot } from './operator-snapshot-state'
import { hasOperatorSnapshotPublication, operatorSnapshotPublication, operatorSnapshotQuery, sameOperatorSnapshotQuery,
  type OperatorSnapshotPublication, type OperatorSnapshotQuery } from './operator-snapshot-contract'

interface Owner {
  readonly authority: ReturnType<typeof captureDashboardObservationOwner>
  readonly instance: string
  readonly recovery: ReturnType<typeof createReadRecovery>
  readonly retiredEpochs: Set<string>
  query: OperatorSnapshotQuery | null
  publication: OperatorSnapshotPublication | null
  displayRevision: number
  lastReadAt: number | null
  refused: boolean
  followup: Promise<void> | null
}
interface Flight { readonly owner: Owner; readonly controller: AbortController; readonly promise: Promise<void>; readonly settle: () => void }
let owner: Owner | null = null
let flight: Flight | null = null
let mounted = 0
let disposeLifetime: (() => void) | null = null
const current = (original: Owner) => owner === original && dashboardObservationOwnerIsCurrent(original.authority)

function cancelRead(original: Owner) {
  if (flight?.owner !== original) return
  const previous = flight
  flight = null
  previous.controller.abort()
  previous.settle()
  operatorLoading.value = false
}

function retire() {
  if (owner !== null) { owner.recovery.dispose(); cancelRead(owner) }
  owner = null
  batch(() => {
    clearOperatorSnapshot(); operatorLoading.value = false
    operatorError.value = null; operatorErrorStatus.value = null
  })
}

function admittedOwner(): Owner | null {
  if (owner !== null && current(owner)) return owner
  retire()
  const authority = captureDashboardObservationOwner()
  if (!dashboardObservationOwnerHasWorkspace(authority)) return null
  owner = { authority, instance: authority.workspace.observerInstanceId, recovery: createReadRecovery(),
    retiredEpochs: new Set(), query: null, publication: null, displayRevision: 0,
    lastReadAt: null, refused: false, followup: null }
  return owner
}

function readAgain(original: Owner) { if (current(original)) void refreshOperatorSnapshot({ force: true }) }

function readFailed(original: Owner, cause: unknown) {
  original.refused = cause instanceof ApiRequestError && (cause.status === 401 || cause.status === 403)
  const summary = extractApiError(cause, 'operator 스냅샷 로드 실패')
  clearOperatorSnapshot(); original.lastReadAt = null
  operatorError.value = summary.message; operatorErrorStatus.value = summary.status
  original.recovery.failed(() => readAgain(original), !original.refused)
}

function validateOutcome(state: OperatorSnapshotPublication['state'], outcome: ProjectionReadOutcome | null) {
  if (state === 'ready' && outcome?.kind !== 'complete') throw new Error('Operator Snapshot omitted its complete read outcome')
  if (state === 'error' && outcome?.kind === 'complete'
    || (state === 'initializing' || state === 'invalidated') && outcome !== null) {
    throw new Error('Operator Snapshot contradicted its read outcome')
  }
}

function installBody(original: Owner, raw: unknown, state: OperatorSnapshotPublication['state'], outcome: ProjectionReadOutcome | null) {
  // Tombstones and no-result failures contain no approval rows to normalize.
  const value = state === 'ready' || outcome?.kind === 'partial' ? normalizeOperatorSnapshot(raw) : null
  const diagnostics = isRecord(raw) && isRecord(raw.projection_diagnostics) ? raw.projection_diagnostics : null
  batch(() => {
    if (value !== null) publishOperatorSnapshot(original.authority, value)
    else clearOperatorSnapshot()
    operatorLoading.value = false
    operatorErrorStatus.value = null
    operatorError.value = state === 'error' ? outcome?.kind === 'partial' ? outcome.error
      : typeof diagnostics?.stale_reason === 'string' ? diagnostics.stale_reason : 'Operator Snapshot source read failed' : null
  })
}

/** A hard mutation withdraws approval rows immediately. Source completion at
 * the same generation leaves an active private read useful, with one trailing read. */
function advance(original: Owner, next: OperatorSnapshotPublication): boolean {
  const previous = original.publication
  if (original.retiredEpochs.has(next.epoch)) return false
  if (previous !== null && next.epoch === previous.epoch) {
    if (next.generation < previous.generation) return false
    if (next.generation === previous.generation && (next.computeSequence < previous.computeSequence
      || next.terminalSequence < previous.terminalSequence
      || next.computeSequence === previous.computeSequence && next.terminalSequence === previous.terminalSequence)) return false
  }
  const hard = next.state === 'invalidated' || previous !== null
    && (next.epoch !== previous.epoch || next.generation > previous.generation)
  if (previous !== null && next.epoch !== previous.epoch) original.retiredEpochs.add(previous.epoch)
  original.publication = next
  if (hard) {
    original.displayRevision++
    original.lastReadAt = null
    clearOperatorSnapshot()
    cancelRead(original)
  }
  return true
}

/** Only the actual Current query can replace its rows with default SSE data. */
export function hydrateOperatorSnapshot(raw: unknown): boolean {
  if (mounted === 0 && owner === null) return false
  const publication = operatorSnapshotPublication(raw)
  const original = admittedOwner()
  if (publication === null || original === null || original.refused || publication.instance !== original.instance) return false
  if (!advance(original, publication)) return false
  if (original.query === null || !sameOperatorSnapshotQuery(original.query, publication.query)) {
    if (publication.state !== 'initializing') readAgain(original)
    return true
  }
  try {
    const outcome = projectionReadOutcome(raw)
    validateOutcome(publication.state, outcome)
    installBody(original, raw, publication.state, outcome)
  }
  catch (cause) { readFailed(original, cause); return false }
  original.displayRevision++
  original.lastReadAt = publication.state === 'ready' ? Date.now() : null
  // A canonical partial/error is the source owner's failed read, not a new
  // client error timer. Reconnect may recover a lost producer completion.
  if (publication.state === 'ready') original.recovery.succeeded()
  else original.recovery.waiting(() => readAgain(original))
  cancelRead(original)
  return true
}

/** Projection errors are rendered here and never reject an executed action's
 * receipt. Force joins owe one read admitted after the existing read. */
export async function refreshOperatorSnapshot(options?: { force?: boolean }): Promise<void> {
  const original = admittedOwner()
  if (original === null || original.refused) return
  if (flight === null && original.followup !== null) return original.followup
  if (flight?.owner === original) {
    if (!options?.force) return flight.promise
    if (original.followup === null) original.followup = flight.promise.then(async () => {
      original.followup = null
      if (current(original) && !original.refused) await refreshOperatorSnapshot({ force: true })
    })
    return original.followup
  }
  if (!options?.force && original.lastReadAt !== null && Date.now() - original.lastReadAt < UI_REFRESH_TTL_MS) return
  let settle!: () => void
  const read: Flight = { owner: original, controller: new AbortController(),
    promise: new Promise<void>(resolve => { settle = resolve }), settle: () => settle() }
  flight = read
  const revision = original.displayRevision
  const accepted = () => current(original) && !read.controller.signal.aborted && original.displayRevision === revision
  original.recovery.started()
  batch(() => { operatorLoading.value = true; operatorError.value = null; operatorErrorStatus.value = null })
  void (async () => {
    try {
      const raw = await fetchOperatorSnapshot({ signal: read.controller.signal })
      if (!accepted()) return
      const query = operatorSnapshotQuery(raw)
      if (!isRecord(raw) || raw.observer_instance_id !== original.instance || query === null) {
        throw new Error('Operator Snapshot did not attest its captured workspace and query')
      }
      if (original.query !== null && !sameOperatorSnapshotQuery(original.query, query)) {
        throw new Error('Operator Snapshot changed the admitted request query')
      }
      if (typeof raw.error === 'string') throw new Error(typeof raw.message === 'string' ? raw.message : raw.error)
      const publication = operatorSnapshotPublication(raw)
      if (publication === null && hasOperatorSnapshotPublication(raw)) throw new Error('Operator Snapshot publication metadata is invalid')
      const outcome = projectionReadOutcome(raw)
      const state = publication?.state ?? (outcome?.kind === 'partial' ? 'error' : 'ready')
      validateOutcome(state, outcome)
      // HTTP may repeat the immutable canonical identity; a newer installed
      // body or mutation has already fenced this flight by displayRevision.
      if (publication !== null && original.publication !== null) {
        const previous = original.publication
        if (original.retiredEpochs.has(publication.epoch)
          || publication.epoch === previous.epoch && (publication.generation < previous.generation
            || publication.generation === previous.generation && (publication.computeSequence < previous.computeSequence
              || publication.terminalSequence < previous.terminalSequence))) return
      }
      installBody(original, raw, state, outcome)
      original.query = query
      if (publication !== null) {
        const previous = original.publication
        if (previous !== null && previous.epoch !== publication.epoch) original.retiredEpochs.add(previous.epoch)
        original.publication = publication
      }
      original.lastReadAt = state === 'ready' ? Date.now() : null
      if (publication === null && outcome?.kind === 'partial') original.recovery.failed(() => readAgain(original))
      else if (state !== 'ready') original.recovery.waiting(() => readAgain(original))
      else original.recovery.succeeded()
    } catch (cause) {
      if (!accepted()) return
      readFailed(original, cause)
    } finally {
      if (flight === read) { flight = null; operatorLoading.value = false }
      read.settle()
    }
  })()
  return read.promise
}

export function setupOperatorSnapshotObservation(): () => void {
  let active = true
  const release = () => {
    if (!active) return
    active = false
    if (--mounted !== 0) return
    disposeLifetime?.(); disposeLifetime = null
    retire()
  }
  if (++mounted > 1) return release
  const replace = () => {
    const previous = owner
    const next = admittedOwner()
    if (next !== null && next !== previous) readAgain(next)
  }
  const recover = () => { admittedOwner()?.recovery.recover() }
  const stopOwner = subscribeDashboardObservationOwnerChanges(replace)
  const stopRecovery = subscribeDashboardObservation({ topics: [] }, () => {}, () => {
    const original = admittedOwner()
    if (original !== null && !original.refused) readAgain(original)
  })
  window.addEventListener('focus', recover); window.addEventListener('online', recover)
  replace()
  disposeLifetime = () => {
    stopOwner(); stopRecovery()
    window.removeEventListener('focus', recover); window.removeEventListener('online', recover)
  }
  return release
}
