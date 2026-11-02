import { effect, signal, type ReadonlySignal } from '@preact/signals'
import { v4 as randomUuid } from 'uuid'
import { callMcpTaskReceiptAtIdentity } from '../../api/mcp'
import { artifactWorkspaceBody, type ArtifactWorkspace } from '../../api/published-artifacts'
import { parseUniqueJson } from '../../lib/json-unique'
import { isRecord } from '../common/normalize'

export const TASK_CREATE_RECEIPT_STORAGE_KEY = 'masc.dashboard.task-create-receipts.v1'
const STORAGE_SCHEMA = 'masc.dashboard.task-create-receipts.v1'

/** These are facts about the original call, independent of later reads. */
export type TaskCreateOriginal =
  | { readonly kind: 'pending' }
  | { readonly kind: 'not_sent' }
  | { readonly kind: 'rejected_before_effect' }
  | { readonly kind: 'unconfirmed'; readonly reason: 'response_unknown' | 'server_error' | 'interrupted' }
  | { readonly kind: 'created'; readonly taskId: string }

export type TaskCreateSettledOriginal = Exclude<TaskCreateOriginal, { kind: 'pending' }>

/** A recorded creation is not a claim about current Task status or existence. */
export type TaskCreationObservation =
  | { readonly kind: 'not_observed'; readonly backlogVersion: number }
  | { readonly kind: 'recorded'; readonly taskId: string; readonly backlogVersion: number }
  | { readonly kind: 'ambiguous'; readonly taskIds: readonly string[]; readonly backlogVersion: number }

export type TaskCreationRead = TaskCreationObservation
  | { readonly kind: 'error'; readonly reason: 'lookup_failed' | 'invalid_response' }

export interface TaskCreateAttempt {
  readonly requestId: string
  readonly workspace: ArtifactWorkspace
  readonly goalId: string | null
  readonly createdAt: string
  readonly persistence: 'session' | 'memory'
  readonly original: TaskCreateOriginal
  /** A confirmed original response has been presented to its submitting draft. */
  readonly presented: boolean
  readonly reads: readonly TaskCreationRead[]
  readonly checking: boolean
  /** False after owner change or restoration, even when paths later match. */
  readonly originalCurrent: boolean
  /** A valid, workspace-bound receipt read under the current owner. */
  readonly latestReadCurrent: boolean
  /** The latest current-owner read failed; never authorizes stored evidence. */
  readonly latestReadFailureCurrent: boolean
}

/** A negative read can predate a success; retain it without declaring a contradiction. */
export function hasUnresolvedTaskCreationEvidence(item: Pick<TaskCreateAttempt, 'original' | 'reads'>): boolean {
  return item.reads.some(read => {
    if (read.kind === 'ambiguous') return true
    if (read.kind === 'not_observed') return item.original.kind === 'created'
    if (read.kind !== 'recorded') return false
    if (item.original.kind === 'created') return read.taskId !== item.original.taskId
    return item.original.kind === 'not_sent' || item.original.kind === 'rejected_before_effect'
  })
}

/** The caller must publish a new immutable owner whenever authority, actor,
 * credential, or workspace changes. isCurrent checks those same live inputs. */
export interface TaskReceiptOwner {
  readonly workspace: ArtifactWorkspace
  readonly identity: { readonly revision: number; readonly actor: string }
  readonly access: 'create_and_read' | 'read_only'
  readonly isCurrent: () => boolean
}

export interface TaskCreateReservation {
  readonly requestId: string
  readonly workspace: ArtifactWorkspace
  readonly identity: TaskReceiptOwner['identity']
  readonly persistence: 'session' | 'memory'
  /** Pass this guard to the original scoped MCP write. */
  readonly isCurrent: () => boolean
}

export type TaskReceiptStorageState = 'ready' | 'read_failed' | 'write_failed' | 'corrupt'
export type TaskCreateReserveResult =
  | { readonly kind: 'reserved'; readonly reservation: TaskCreateReservation }
  | { readonly kind: 'owner_unavailable' | 'storage_unavailable' | 'invalid_goal' | 'duplicate_request_id' | 'id_unavailable' | 'disposed' }
export type TaskCreateSettleResult =
  | { readonly kind: 'settled'; readonly persisted: boolean }
  | { readonly kind: 'not_found' | 'already_settled' | 'invalid_result' | 'disposed' }
export type TaskCreateObserveResult =
  | { readonly kind: 'observed'; readonly result: TaskCreationRead; readonly persisted: boolean }
  | { readonly kind: 'not_found' | 'owner_unavailable' | 'workspace_mismatch' | 'already_checking' | 'stale' | 'disposed' }

type ReceiptStorage = Pick<Storage, 'getItem' | 'setItem'>
type ReceiptLookup = (owner: TaskReceiptOwner, requestId: string, isCurrent: () => boolean) => Promise<string>

export interface TaskCreateReceiptStore {
  readonly attempts: ReadonlySignal<readonly TaskCreateAttempt[]>
  readonly storageState: ReadonlySignal<TaskReceiptStorageState>
  /** Reserves and persists metadata, but performs no network request. */
  readonly reserve: (goalId?: string | null) => TaskCreateReserveResult
  /** Explicit caller choice: this reservation will not survive a reload. */
  readonly reserveMemoryOnly: (goalId?: string | null) => TaskCreateReserveResult
  /** Retains the original outcome even when the original view has retired. */
  readonly settleOriginal: (requestId: string, result: TaskCreateSettledOriginal) => TaskCreateSettleResult
  /** Marks an already-confirmed response as presented; it never creates a Task. */
  readonly markPresented: (requestId: string) => boolean
  /** Removes only this current owner's definite, unambiguous outcome. */
  readonly forgetDefinite: (requestId: string) => boolean
  /** A deliberate read only. No creation or lookup request is replayed. */
  readonly observe: (requestId: string) => Promise<TaskCreateObserveResult>
  readonly retryStorage: () => boolean
  /** Explicitly remove presented/definite records and redundant identical read errors. */
  readonly compact: () => { readonly removedAttempts: number; readonly removedErrors: number;
    readonly removedReads: number; readonly persisted: boolean }
  readonly dispose: () => void
}

function nonblank(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value)
  return actual.length === keys.length && keys.every(key => Object.hasOwn(value, key))
}

function workspaceValue(value: unknown): ArtifactWorkspace | null {
  if (!isRecord(value) || !exactKeys(value, ['basePath', 'mascRoot'])
    || !nonblank(value.basePath) || !nonblank(value.mascRoot)) return null
  return { basePath: value.basePath, mascRoot: value.mascRoot }
}

function sameWorkspace(a: ArtifactWorkspace, b: ArtifactWorkspace): boolean {
  return a.basePath === b.basePath && a.mascRoot === b.mascRoot
}

function positiveVersion(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0
}

function canonicalTimestamp(value: unknown): value is string {
  if (typeof value !== 'string') return false
  const date = new Date(value)
  return Number.isFinite(date.getTime()) && date.toISOString() === value
}

function sameObservationContent(a: TaskCreationObservation, b: TaskCreationObservation): boolean {
  if (a.kind !== b.kind) return false
  if (a.kind === 'not_observed' && b.kind === 'not_observed') return true
  if (a.kind === 'recorded' && b.kind === 'recorded') return a.taskId === b.taskId
  if (a.kind === 'ambiguous' && b.kind === 'ambiguous') {
    return a.taskIds.length === b.taskIds.length && a.taskIds.every((id, index) => id === b.taskIds[index])
  }
  return false
}

function summarizeReads(reads: readonly TaskCreationRead[]): readonly TaskCreationRead[] {
  const result: TaskCreationRead[] = []
  let firstObservation: number | null = null
  let lastObservation: number | null = null
  let previousObservation: TaskCreationObservation | null = null
  const errors = new Map<string, { first: number; last: number }>()
  const flush = () => {
    const indices = new Set<number>()
    if (firstObservation !== null) indices.add(firstObservation)
    if (lastObservation !== null) indices.add(lastObservation)
    for (const error of errors.values()) { indices.add(error.first); indices.add(error.last) }
    for (const index of [...indices].sort((a, b) => a - b)) {
      const read = reads[index]
      if (read) result.push(read)
    }
    firstObservation = null
    lastObservation = null
    previousObservation = null
    errors.clear()
  }
  reads.forEach((read, index) => {
    if (read.kind === 'error') {
      const previous = errors.get(read.reason)
      if (previous) previous.last = index
      else errors.set(read.reason, { first: index, last: index })
      return
    }
    if (previousObservation && (!sameObservationContent(previousObservation, read)
      || read.backlogVersion < previousObservation.backlogVersion)) flush()
    if (firstObservation === null) firstObservation = index
    lastObservation = index
    previousObservation = read
  })
  flush()
  return result
}

function appendRead(reads: readonly TaskCreationRead[], next: TaskCreationRead): readonly TaskCreationRead[] {
  if (next.kind !== 'error') {
    // Only rewrite the current observation segment. Older stored segments are
    // compacted explicitly once an authenticated read grants that authority.
    let previous: TaskCreationObservation = next
    let start = reads.length
    for (let index = reads.length - 1; index >= 0; index--) {
      const read = reads[index]
      if (!read || read.kind === 'error') continue
      if (!sameObservationContent(read, previous) || read.backlogVersion > previous.backlogVersion) break
      start = index
      previous = read
    }
    return [...reads.slice(0, start), ...summarizeReads([...reads.slice(start), next])]
  }
  // A failed read does not authorize rewriting earlier observed facts. Only
  // summarize the trailing errors until a valid scoped read succeeds.
  let errorStart = reads.length
  while (errorStart > 0 && reads[errorStart - 1]?.kind === 'error') errorStart--
  return [...reads.slice(0, errorStart), ...summarizeReads([...reads.slice(errorStart), next])]
}

/** Decode the exact original request and workspace, with state cardinality. */
export function decodeTaskCreationReceipt(raw: string, requestId: string,
  workspace: ArtifactWorkspace): TaskCreationObservation | null {
  let value: unknown
  try { value = parseUniqueJson(raw) } catch { return null }
  if (!isRecord(value) || value.ok !== true || value.creation_request_id !== requestId
    || !positiveVersion(value.backlog_version) || !isRecord(value.workspace)
    || !exactKeys(value.workspace, ['base_path', 'masc_root'])
    || value.workspace.base_path !== workspace.basePath || value.workspace.masc_root !== workspace.mascRoot
    || !isRecord(value.creation_receipt) || !exactKeys(value.creation_receipt, ['state', 'task_ids'])) return null
  const { state, task_ids: ids } = value.creation_receipt
  if (!Array.isArray(ids) || !ids.every(nonblank)) return null
  const backlogVersion = value.backlog_version
  if (state === 'not_observed' && ids.length === 0) return { kind: 'not_observed', backlogVersion }
  const taskId: unknown = ids[0]
  if (state === 'recorded' && ids.length === 1 && nonblank(taskId)) return { kind: 'recorded', taskId, backlogVersion }
  if (state === 'ambiguous' && ids.length >= 2) return { kind: 'ambiguous', taskIds: [...ids], backlogVersion }
  return null
}

/** A successful transport is not enough: the response must name this request. */
export function decodeTaskCreationResponse(raw: string, requestId: string,
  goalId: string | null): Extract<TaskCreateSettledOriginal, { kind: 'created' }> | null {
  let value: unknown
  try { value = parseUniqueJson(raw) } catch { return null }
  if (!isRecord(value) || value.ok !== true || value.creation_request_id !== requestId
    || value.goal_id !== goalId || !nonblank(value.task_id)) return null
  return { kind: 'created', taskId: value.task_id }
}

function decodeOriginal(value: unknown, restore: boolean): TaskCreateOriginal | null {
  if (!isRecord(value)) return null
  if (value.kind === 'pending' && exactKeys(value, ['kind'])) {
    return restore ? { kind: 'unconfirmed', reason: 'interrupted' } : { kind: 'pending' }
  }
  if (value.kind === 'not_sent' && exactKeys(value, ['kind'])) return { kind: 'not_sent' }
  if (value.kind === 'rejected_before_effect' && exactKeys(value, ['kind'])) return { kind: 'rejected_before_effect' }
  if (value.kind === 'unconfirmed' && exactKeys(value, ['kind', 'reason'])
    && (value.reason === 'response_unknown' || value.reason === 'server_error' || value.reason === 'interrupted')) {
    return { kind: 'unconfirmed', reason: value.reason }
  }
  if (value.kind === 'created' && exactKeys(value, ['kind', 'taskId']) && nonblank(value.taskId)) {
    return { kind: 'created', taskId: value.taskId }
  }
  return null
}

function decodeStoredRead(value: unknown): TaskCreationRead | null {
  if (!isRecord(value)) return null
  if (value.kind === 'error' && exactKeys(value, ['kind', 'reason'])
    && (value.reason === 'lookup_failed' || value.reason === 'invalid_response')) {
    return { kind: 'error', reason: value.reason }
  }
  if (!positiveVersion(value.backlogVersion)) return null
  if (value.kind === 'not_observed' && exactKeys(value, ['kind', 'backlogVersion'])) {
    return { kind: 'not_observed', backlogVersion: value.backlogVersion }
  }
  if (value.kind === 'recorded' && exactKeys(value, ['kind', 'taskId', 'backlogVersion']) && nonblank(value.taskId)) {
    return { kind: 'recorded', taskId: value.taskId, backlogVersion: value.backlogVersion }
  }
  if (value.kind === 'ambiguous' && exactKeys(value, ['kind', 'taskIds', 'backlogVersion'])
    && Array.isArray(value.taskIds) && value.taskIds.length >= 2 && value.taskIds.every(nonblank)) {
    return { kind: 'ambiguous', taskIds: [...value.taskIds], backlogVersion: value.backlogVersion }
  }
  return null
}

function decodeStored(raw: string): TaskCreateAttempt[] | null {
  let data: unknown
  try { data = parseUniqueJson(raw) } catch { return null }
  if (!isRecord(data) || !exactKeys(data, ['schema', 'attempts']) || data.schema !== STORAGE_SCHEMA
    || !Array.isArray(data.attempts)) return null
  const seen = new Set<string>()
  const attempts: TaskCreateAttempt[] = []
  for (const item of data.attempts) {
    if (!isRecord(item) || !exactKeys(item, ['requestId', 'workspace', 'goalId', 'createdAt', 'original', 'presented', 'reads'])
      || !nonblank(item.requestId) || seen.has(item.requestId)
      || !(item.goalId === null || nonblank(item.goalId)) || !canonicalTimestamp(item.createdAt)
      || typeof item.presented !== 'boolean' || !Array.isArray(item.reads)) return null
    const workspace = workspaceValue(item.workspace)
    const original = decodeOriginal(item.original, true)
    const reads = item.reads.map(decodeStoredRead)
    if (!workspace || !original || (item.presented && original.kind !== 'created') || reads.some(read => read === null)) return null
    seen.add(item.requestId)
    attempts.push({ requestId: item.requestId, workspace, goalId: item.goalId, createdAt: item.createdAt,
      persistence: 'session', original, presented: item.presented,
      reads: reads as TaskCreationRead[], checking: false, originalCurrent: false, latestReadCurrent: false,
      latestReadFailureCurrent: false })
  }
  return attempts
}

function encodeStored(attempts: readonly TaskCreateAttempt[]): string {
  // Explicit projection: no credential, Task title, description, or body.
  return JSON.stringify({ schema: STORAGE_SCHEMA, attempts: attempts.filter(attempt => attempt.persistence === 'session').map(attempt => ({
    requestId: attempt.requestId,
    workspace: { basePath: attempt.workspace.basePath, mascRoot: attempt.workspace.mascRoot },
    goalId: attempt.goalId,
    createdAt: attempt.createdAt,
    original: attempt.original,
    presented: attempt.presented,
    reads: attempt.reads,
  })) })
}

function browserSessionStorage(): ReceiptStorage | null {
  try { return globalThis.sessionStorage ?? null } catch { return null }
}

const defaultLookup: ReceiptLookup = (owner, requestId, isCurrent) =>
  callMcpTaskReceiptAtIdentity({ creation_request_id: requestId,
    expected_workspace: artifactWorkspaceBody(owner.workspace) }, owner.identity, isCurrent)

export function createTaskCreateReceiptStore(options: {
  readonly owner: ReadonlySignal<TaskReceiptOwner | null>
  /** Null explicitly means storage is unavailable. Omit for sessionStorage. */
  readonly storage?: ReceiptStorage | null
  readonly lookup?: ReceiptLookup
  readonly newRequestId?: () => string
}): TaskCreateReceiptStore {
  let storage = options.storage === undefined ? browserSessionStorage() : options.storage
  const lookup = options.lookup ?? defaultLookup
  const newRequestId = options.newRequestId ?? randomUuid
  const attempts = signal<readonly TaskCreateAttempt[]>([])
  const storageState = signal<TaskReceiptStorageState>('read_failed')
  const originalGuards = new Map<string, () => boolean>()
  const reads = new Map<string, symbol>()
  let ownerEpoch = 0
  let disposed = false

  const loadStorage = (): boolean => {
    if (!storage) { storageState.value = 'read_failed'; return false }
    try {
      const raw = storage.getItem(TASK_CREATE_RECEIPT_STORAGE_KEY)
      const loaded = raw === null ? [] : decodeStored(raw)
      if (loaded === null) { storageState.value = 'corrupt'; return false }
      const memory = attempts.peek().filter(item => item.persistence === 'memory')
      if (memory.some(item => loaded.some(stored => stored.requestId === item.requestId))) {
        storageState.value = 'corrupt'
        return false
      }
      attempts.value = [...loaded, ...memory]
      storageState.value = 'ready'
      return true
    } catch { storageState.value = 'read_failed'; return false }
  }
  loadStorage()

  const stopOwnerEffect = effect(() => {
    void options.owner.value
    ownerEpoch += 1
    reads.clear()
    const existing = attempts.peek()
    if (existing.some(item => item.checking || item.originalCurrent || item.latestReadCurrent || item.latestReadFailureCurrent)) {
      attempts.value = existing.map(item => ({ ...item, checking: false, originalCurrent: false, latestReadCurrent: false,
        latestReadFailureCurrent: false }))
    }
  })

  const save = (next: readonly TaskCreateAttempt[]): boolean => {
    if (!storage || storageState.peek() !== 'ready') return false
    try {
      storage.setItem(TASK_CREATE_RECEIPT_STORAGE_KEY, encodeStored(next))
      return true
    } catch { storageState.value = 'write_failed'; return false }
  }

  const ownerGuard = (owner: TaskReceiptOwner, epoch: number, workspace: ArtifactWorkspace,
    identity: TaskReceiptOwner['identity']) => () => {
    if (disposed || ownerEpoch !== epoch || options.owner.peek() !== owner
      || !sameWorkspace(owner.workspace, workspace) || owner.identity.revision !== identity.revision
      || owner.identity.actor !== identity.actor) return false
    try { return owner.isCurrent() } catch { return false }
  }

  const canManage = (item: TaskCreateAttempt): boolean => {
    const owner = options.owner.peek()
    return Boolean(owner && sameWorkspace(owner.workspace, item.workspace)
      && ownerGuard(owner, ownerEpoch, item.workspace, owner.identity)()
      && !item.latestReadFailureCurrent && (item.originalCurrent || item.latestReadCurrent))
  }

  const definite = (item: TaskCreateAttempt): boolean =>
    item.original.kind === 'not_sent' || item.original.kind === 'rejected_before_effect'
      || (item.original.kind === 'created' && item.presented)

  const canForget = (item: TaskCreateAttempt): boolean =>
    canManage(item) && definite(item) && !item.checking && !hasUnresolvedTaskCreationEvidence(item)

  const reserveWith = (persistence: 'session' | 'memory', goalId: string | null = null): TaskCreateReserveResult => {
    if (disposed) return { kind: 'disposed' }
    if (persistence === 'session' && storageState.peek() !== 'ready') return { kind: 'storage_unavailable' }
    if (goalId !== null && !nonblank(goalId)) return { kind: 'invalid_goal' }
    const owner = options.owner.peek()
    if (!owner || owner.access !== 'create_and_read' || !workspaceValue(owner.workspace)) return { kind: 'owner_unavailable' }
    const workspace = { basePath: owner.workspace.basePath, mascRoot: owner.workspace.mascRoot }
    const identity = { revision: owner.identity.revision, actor: owner.identity.actor }
    const isCurrent = ownerGuard(owner, ownerEpoch, workspace, identity)
    if (!isCurrent()) return { kind: 'owner_unavailable' }
    let requestId: string
    try { requestId = newRequestId() } catch { return { kind: 'id_unavailable' } }
    if (!nonblank(requestId)) return { kind: 'id_unavailable' }
    if (attempts.peek().some(item => item.requestId === requestId)) return { kind: 'duplicate_request_id' }
    const attempt: TaskCreateAttempt = { requestId, workspace, goalId, createdAt: new Date().toISOString(), persistence,
      original: { kind: 'pending' }, presented: false, reads: [],
      checking: false, originalCurrent: true, latestReadCurrent: false, latestReadFailureCurrent: false }
    const next = [...attempts.peek(), attempt]
    if (persistence === 'session' && !save(next)) return { kind: 'storage_unavailable' }
    originalGuards.set(requestId, isCurrent)
    attempts.value = [...next.slice(0, -1), { ...attempt, originalCurrent: isCurrent() }]
    return { kind: 'reserved', reservation: { requestId, workspace: { ...workspace }, identity, persistence, isCurrent } }
  }
  const reserve = (goalId: string | null = null) => reserveWith('session', goalId)
  const reserveMemoryOnly = (goalId: string | null = null) => reserveWith('memory', goalId)

  const settleOriginal = (requestId: string, result: TaskCreateSettledOriginal): TaskCreateSettleResult => {
    if (disposed) return { kind: 'disposed' }
    const existing = attempts.peek().find(item => item.requestId === requestId)
    if (!existing) return { kind: 'not_found' }
    if (existing.original.kind !== 'pending') return { kind: 'already_settled' }
    const decoded = decodeOriginal(result, false)
    if (!decoded || decoded.kind === 'pending') return { kind: 'invalid_result' }
    const next = attempts.peek().map(item => item.requestId === requestId
      ? { ...item, original: decoded, originalCurrent: originalGuards.get(requestId)?.() === true } : item)
    attempts.value = next
    const persisted = existing.persistence === 'session' && save(attempts.peek())
    originalGuards.delete(requestId)
    return { kind: 'settled', persisted }
  }

  const markPresented = (requestId: string): boolean => {
    if (disposed) return false
    const existing = attempts.peek().find(item => item.requestId === requestId)
    if (!existing || existing.original.kind !== 'created') return false
    attempts.value = attempts.peek().map(item => item.requestId === requestId ? { ...item, presented: true } : item)
    if (existing.persistence === 'session') save(attempts.peek())
    return true
  }

  const forgetDefinite = (requestId: string): boolean => {
    if (disposed) return false
    const item = attempts.peek().find(attempt => attempt.requestId === requestId)
    if (!item || !canForget(item)) return false
    const next = attempts.peek().filter(attempt => attempt.requestId !== requestId)
    // Keep the in-memory evidence if a session-backed deletion cannot persist.
    if (item.persistence === 'session' && !save(next)) return false
    attempts.value = next
    return true
  }

  const observe = async (requestId: string): Promise<TaskCreateObserveResult> => {
    if (disposed) return { kind: 'disposed' }
    const existing = attempts.peek().find(item => item.requestId === requestId)
    if (!existing) return { kind: 'not_found' }
    const owner = options.owner.peek()
    if (!owner || !workspaceValue(owner.workspace)) return { kind: 'owner_unavailable' }
    if (!sameWorkspace(owner.workspace, existing.workspace)) return { kind: 'workspace_mismatch' }
    const identity = { revision: owner.identity.revision, actor: owner.identity.actor }
    const ownerIsCurrent = ownerGuard(owner, ownerEpoch, existing.workspace, identity)
    if (!ownerIsCurrent()) return { kind: 'owner_unavailable' }
    if (reads.has(requestId)) return { kind: 'already_checking' }
    const ticket = Symbol('task-creation-read')
    reads.set(requestId, ticket)
    const isCurrent = () => ownerIsCurrent() && reads.get(requestId) === ticket
    attempts.value = attempts.peek().map(item => item.requestId === requestId ? { ...item, checking: true } : item)
    if (!isCurrent()) {
      if (reads.get(requestId) === ticket) reads.delete(requestId)
      attempts.value = attempts.peek().map(item => item.requestId === requestId ? { ...item, checking: false } : item)
      return { kind: 'stale' }
    }
    let result: TaskCreationRead
    try {
      const raw = await lookup(owner, requestId, isCurrent)
      if (!isCurrent()) return { kind: 'stale' }
      result = decodeTaskCreationReceipt(raw, requestId, existing.workspace) ?? { kind: 'error', reason: 'invalid_response' }
    } catch {
      if (!isCurrent()) return { kind: 'stale' }
      result = { kind: 'error', reason: 'lookup_failed' }
    } finally {
      if (reads.get(requestId) === ticket) {
        reads.delete(requestId)
        if (!ownerIsCurrent()) {
          attempts.value = attempts.peek().map(item => item.requestId === requestId ? { ...item, checking: false } : item)
        }
      }
    }
    // No await occurs between the final owner check and admitting this read.
    if (!ownerIsCurrent()) return { kind: 'stale' }
    const next = attempts.peek().map(item => item.requestId === requestId
      ? { ...item, reads: appendRead(item.reads, result), checking: false,
        latestReadCurrent: result.kind !== 'error', latestReadFailureCurrent: result.kind === 'error' } : item)
    attempts.value = next
    const persisted = existing.persistence === 'session' && save(attempts.peek())
    return { kind: 'observed', result, persisted }
  }

  const retryStorage = (): boolean => {
    if (disposed) return false
    if (!storage && options.storage === undefined) storage = browserSessionStorage()
    if (!storage) return false
    if (storageState.peek() === 'read_failed' || storageState.peek() === 'corrupt') return loadStorage()
    if (storageState.peek() === 'ready') return true
    try {
      storage.setItem(TASK_CREATE_RECEIPT_STORAGE_KEY, encodeStored(attempts.peek()))
      storageState.value = 'ready'
      return true
    } catch { storageState.value = 'write_failed'; return false }
  }

  const compact = () => {
    let removedAttempts = 0
    let removedErrors = 0
    let removedReads = 0
    const next: TaskCreateAttempt[] = []
    for (const item of attempts.peek()) {
      if (item.checking || !canManage(item)) { next.push(item); continue }
      if (canForget(item)) {
        removedAttempts++
        continue
      }
      const retained = summarizeReads(item.reads)
      const beforeErrors = item.reads.filter(read => read.kind === 'error').length
      const afterErrors = retained.filter(read => read.kind === 'error').length
      removedErrors += beforeErrors - afterErrors
      removedReads += item.reads.length - retained.length - (beforeErrors - afterErrors)
      next.push({ ...item, reads: retained })
    }
    if (disposed) return { removedAttempts: 0, removedErrors: 0, removedReads: 0, persisted: false }
    attempts.value = next
    const persisted = storageState.peek() === 'ready' ? save(next)
      : storageState.peek() === 'write_failed' ? retryStorage() : false
    return { removedAttempts, removedErrors, removedReads, persisted }
  }

  const dispose = () => {
    if (disposed) return
    disposed = true
    ownerEpoch += 1
    reads.clear()
    stopOwnerEffect()
    attempts.value = attempts.peek().map(item => ({ ...item, checking: false, originalCurrent: false, latestReadCurrent: false,
      latestReadFailureCurrent: false }))
  }

  return { attempts, storageState, reserve, reserveMemoryOnly, settleOriginal, markPresented, forgetDefinite,
    observe, retryStorage, compact, dispose }
}
