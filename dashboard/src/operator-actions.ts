import {
  confirmOperatorAction,
  currentStoredTokenRevision,
  subscribeStoredTokenChanges,
  extractApiError,
  fetchOperatorDigest,
  fetchOperatorSnapshot,
  runOperatorAction,
} from './api/core'
import type {
  OperatorActionLogEntry,
  OperatorActionRequest,
  OperatorActionResult,
  RefreshOptions,
} from './types'
import { registerOperatorRefresh } from './sse-store'
import { UI_REFRESH_TTL_MS } from './config/constants'
import { UNKNOWN_STATUS_LABEL } from './lib/format-string'
import {
  operatorSnapshot,
  operatorWorkspaceDigest,
  operatorLoading,
  operatorError,
  operatorErrorStatus,
  operatorDigestLoading,
  operatorDigestError,
  operatorDigestErrorStatus,
  acquireOperatorAction,
  operatorActionLog,
} from './operator-signals'
import { normalizeOperatorSnapshot, normalizeOperatorDigest } from './operator-normalizers'

let nextLogId = 1

interface OwnedRefresh {
  readonly authRevision: number
  readonly promise: Promise<void>
}
interface RefreshReceipt {
  readonly authRevision: number
  readonly at: number
}
let snapshotRefreshInflight: OwnedRefresh | null = null
let workspaceDigestRefreshInflight: OwnedRefresh | null = null
let snapshotFollowup: OwnedRefresh | null = null
let digestFollowup: OwnedRefresh | null = null
let lastSnapshotRefresh: RefreshReceipt | null = null
let lastWorkspaceDigestRefresh: RefreshReceipt | null = null

function createRefreshOperation(authRevision: number) {
  let resolve!: () => void
  let reject!: (error: unknown) => void
  const promise = new Promise<void>((done, fail) => { resolve = done; reject = fail })
  return { operation: Object.freeze({ authRevision, promise }), resolve, reject }
}

function stringifyUnknown(value: unknown): string {
  if (typeof value === 'string') return value
  if (value === null || value === undefined) return ''
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function targetLabelOf(request: Pick<OperatorActionRequest, 'target_type' | 'target_id'>): string {
  return request.target_id ? `${request.target_type}:${request.target_id}` : request.target_type
}

function appendLog(entry: Omit<OperatorActionLogEntry, 'id' | 'at'>): void {
  operatorActionLog.value = [
    {
      ...entry,
      id: nextLogId++,
      at: new Date().toISOString(),
    },
    ...operatorActionLog.value,
  ].slice(0, 20)
}

function logMessageFromResult(result: OperatorActionResult): string {
  if (result.confirm_required) {
    return stringifyUnknown(result.preview) || UNKNOWN_STATUS_LABEL
  }
  return stringifyUnknown(result.result)
    || stringifyUnknown(result.executed_action)
    || result.status
}

function isFresh(receipt: RefreshReceipt | null, authRevision: number, opts?: RefreshOptions): boolean {
  return !opts?.force && receipt !== null && receipt.authRevision === authRevision
    && Date.now() - receipt.at < UI_REFRESH_TTL_MS
}

export async function refreshOperatorSnapshot(opts?: RefreshOptions): Promise<void> {
  const authRevision = currentStoredTokenRevision()
  const existing = snapshotRefreshInflight
  if (existing && existing.authRevision === authRevision) {
    if (!opts?.force) return existing.promise
    if (!snapshotFollowup || snapshotFollowup.authRevision !== authRevision) {
      const pending = createRefreshOperation(authRevision)
      snapshotFollowup = pending.operation
      void existing.promise.then(async () => {
        if (snapshotFollowup !== pending.operation || currentStoredTokenRevision() !== authRevision) return
        snapshotFollowup = null
        await refreshOperatorSnapshot({ force: true })
      }).finally(() => {
        if (snapshotFollowup === pending.operation) snapshotFollowup = null
      }).then(pending.resolve, pending.reject)
    }
    return snapshotFollowup.promise
  }
  if (isFresh(lastSnapshotRefresh, authRevision, opts)) return
  const pending = createRefreshOperation(authRevision)
  const operation = pending.operation
  const controller = new AbortController()
  const releaseAuth = subscribeStoredTokenChanges(() => {
    if (currentStoredTokenRevision() !== authRevision) controller.abort()
  })
  snapshotRefreshInflight = operation
  const owns = () => snapshotRefreshInflight === operation && currentStoredTokenRevision() === authRevision
  void (async () => {
    try {
      operatorLoading.value = true
      if (!owns()) return
      operatorError.value = null
      if (!owns()) return
      operatorErrorStatus.value = null
      if (!owns()) return
      const raw = await fetchOperatorSnapshot({ signal: controller.signal })
      if (!owns()) return
      operatorSnapshot.value = normalizeOperatorSnapshot(raw)
      if (!owns()) return
      lastSnapshotRefresh = Object.freeze({ authRevision, at: Date.now() })
    } catch (error) {
      if (!owns()) return
      const summary = extractApiError(error, 'operator 스냅샷 로드 실패')
      operatorSnapshot.value = null
      if (!owns()) return
      lastSnapshotRefresh = null
      operatorError.value = summary.message
      if (!owns()) return
      operatorErrorStatus.value = summary.status
    } finally {
      try {
        if (owns()) operatorLoading.value = false
      } finally {
        if (snapshotRefreshInflight === operation) snapshotRefreshInflight = null
        releaseAuth()
      }
    }
  })().then(pending.resolve, pending.reject)
  return operation.promise
}

export async function refreshOperatorWorkspaceDigest(opts?: RefreshOptions): Promise<void> {
  const authRevision = currentStoredTokenRevision()
  const existing = workspaceDigestRefreshInflight
  if (existing && existing.authRevision === authRevision) {
    if (!opts?.force) return existing.promise
    if (!digestFollowup || digestFollowup.authRevision !== authRevision) {
      const pending = createRefreshOperation(authRevision)
      digestFollowup = pending.operation
      void existing.promise.then(async () => {
        if (digestFollowup !== pending.operation || currentStoredTokenRevision() !== authRevision) return
        digestFollowup = null
        await refreshOperatorWorkspaceDigest({ force: true })
      }).finally(() => {
        if (digestFollowup === pending.operation) digestFollowup = null
      }).then(pending.resolve, pending.reject)
    }
    return digestFollowup.promise
  }
  if (isFresh(lastWorkspaceDigestRefresh, authRevision, opts)) return
  const pending = createRefreshOperation(authRevision)
  const operation = pending.operation
  const controller = new AbortController()
  const releaseAuth = subscribeStoredTokenChanges(() => {
    if (currentStoredTokenRevision() !== authRevision) controller.abort()
  })
  workspaceDigestRefreshInflight = operation
  const owns = () => workspaceDigestRefreshInflight === operation && currentStoredTokenRevision() === authRevision
  void (async () => {
    try {
      operatorDigestLoading.value = true
      if (!owns()) return
      operatorDigestError.value = null
      if (!owns()) return
      operatorDigestErrorStatus.value = null
      if (!owns()) return
      const raw = await fetchOperatorDigest({ targetType: 'namespace', signal: controller.signal })
      if (!owns()) return
      operatorWorkspaceDigest.value = normalizeOperatorDigest(raw)
      if (!owns()) return
      lastWorkspaceDigestRefresh = Object.freeze({ authRevision, at: Date.now() })
    } catch (error) {
      if (!owns()) return
      const summary = extractApiError(error, 'operator 다이제스트 로드 실패')
      lastWorkspaceDigestRefresh = null
      operatorDigestError.value = summary.message
      if (!owns()) return
      operatorDigestErrorStatus.value = summary.status
    } finally {
      try {
        if (owns()) operatorDigestLoading.value = false
      } finally {
        if (workspaceDigestRefreshInflight === operation) workspaceDigestRefreshInflight = null
        releaseAuth()
      }
    }
  })().then(pending.resolve, pending.reject)
  return operation.promise
}

export class OperatorActionAuthenticationSupersededError extends Error {
  constructor() {
    super('Operator action authentication changed before admission')
    this.name = 'OperatorActionAuthenticationSupersededError'
  }
}

function assertActionAdmission(authRevision: number): void {
  if (currentStoredTokenRevision() !== authRevision) {
    throw new OperatorActionAuthenticationSupersededError()
  }
}

type ActionRefreshOptions = { refresh?: 'await' | 'background' }

async function refreshAfterAction(options: ActionRefreshOptions, authRevision: number): Promise<void> {
  if (currentStoredTokenRevision() !== authRevision) return
  const reads = [refreshOperatorSnapshot({ force: true })]
  if (currentStoredTokenRevision() === authRevision) {
    reads.push(refreshOperatorWorkspaceDigest({ force: true }))
  }
  const refreshed = Promise.all(reads)
  if (options.refresh === 'background') {
    // Both stores report their own read errors. A projection is not the action
    // receipt and must not hold its confirmation token or acknowledgement.
    void refreshed
  } else {
    await refreshed
  }
}

export async function dispatchOperatorAction(
  request: OperatorActionRequest,
  options: ActionRefreshOptions = {},
): Promise<OperatorActionResult> {
  const authRevision = currentStoredTokenRevision()
  const releaseAction = acquireOperatorAction()
  try {
    assertActionAdmission(authRevision)
    operatorError.value = null
    assertActionAdmission(authRevision)
    operatorErrorStatus.value = null
    assertActionAdmission(authRevision)
    const result = await runOperatorAction(request)
    if (currentStoredTokenRevision() !== authRevision) return result
    appendLog({
      actor: request.actor,
      action_type: request.action_type,
      target_label: targetLabelOf(request),
      outcome: result.confirm_required ? 'preview' : 'executed',
      message: logMessageFromResult(result),
      tool_name: result.tool_name,
    })
    await refreshAfterAction(options, authRevision)
    return result
  } catch (err) {
    if (currentStoredTokenRevision() !== authRevision) throw err
    const summary = extractApiError(err, 'operator 액션 실패')
    const message = summary.message
    operatorError.value = message
    if (currentStoredTokenRevision() !== authRevision) throw err
    operatorErrorStatus.value = summary.status
    if (currentStoredTokenRevision() !== authRevision) throw err
    appendLog({
      actor: request.actor,
      action_type: request.action_type,
      target_label: targetLabelOf(request),
      outcome: 'error',
      message,
    })
    throw err
  } finally {
    releaseAction()
  }
}

export async function confirmOperatorPendingAction(
  actor: string,
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
  options: ActionRefreshOptions = {},
): Promise<OperatorActionResult> {
  const authRevision = currentStoredTokenRevision()
  const releaseAction = acquireOperatorAction()
  try {
    assertActionAdmission(authRevision)
    operatorError.value = null
    assertActionAdmission(authRevision)
    operatorErrorStatus.value = null
    assertActionAdmission(authRevision)
    const result = await confirmOperatorAction(actor, confirmToken, decision)
    if (currentStoredTokenRevision() !== authRevision) return result
    appendLog({
      actor,
      action_type: decision,
      target_label: confirmToken,
      outcome: 'confirmed',
      message: logMessageFromResult(result),
      tool_name: result.tool_name,
    })
    await refreshAfterAction(options, authRevision)
    return result
  } catch (err) {
    if (currentStoredTokenRevision() !== authRevision) throw err
    const summary = extractApiError(err, 'operator 확인 실패')
    const message = summary.message
    operatorError.value = message
    if (currentStoredTokenRevision() !== authRevision) throw err
    operatorErrorStatus.value = summary.status
    if (currentStoredTokenRevision() !== authRevision) throw err
    appendLog({
      actor,
      action_type: decision,
      target_label: confirmToken,
      outcome: 'error',
      message,
    })
    throw err
  } finally {
    releaseAction()
  }
}

registerOperatorRefresh(() => {
  void refreshOperatorSnapshot()
  void refreshOperatorWorkspaceDigest()
})
