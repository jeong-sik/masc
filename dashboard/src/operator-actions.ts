import {
  confirmOperatorAction,
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
  operatorActionBusy,
  operatorActionLog,
} from './operator-signals'
import { normalizeOperatorSnapshot, normalizeOperatorDigest } from './operator-normalizers'

let nextLogId = 1

let snapshotRefreshInflight: Promise<void> | null = null
let workspaceDigestRefreshInflight: Promise<void> | null = null
let lastSnapshotRefreshAt = 0
let lastWorkspaceDigestRefreshAt = 0

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

function isFresh(lastAt: number, opts?: RefreshOptions): boolean {
  return !opts?.force && Date.now() - lastAt < UI_REFRESH_TTL_MS
}

export async function refreshOperatorSnapshot(opts?: RefreshOptions): Promise<void> {
  if (snapshotRefreshInflight) return snapshotRefreshInflight
  if (isFresh(lastSnapshotRefreshAt, opts)) return
  operatorLoading.value = true
  operatorError.value = null
  operatorErrorStatus.value = null
  snapshotRefreshInflight = (async () => {
    try {
      const raw = await fetchOperatorSnapshot()
      operatorSnapshot.value = normalizeOperatorSnapshot(raw)
      lastSnapshotRefreshAt = Date.now()
    } catch (err) {
      const summary = extractApiError(err, 'operator 스냅샷 로드 실패')
      operatorError.value = summary.message
      operatorErrorStatus.value = summary.status
    } finally {
      operatorLoading.value = false
      snapshotRefreshInflight = null
    }
  })()
  return snapshotRefreshInflight
}

export async function refreshOperatorWorkspaceDigest(opts?: RefreshOptions): Promise<void> {
  if (workspaceDigestRefreshInflight) return workspaceDigestRefreshInflight
  if (isFresh(lastWorkspaceDigestRefreshAt, opts)) return
  operatorDigestLoading.value = true
  operatorDigestError.value = null
  operatorDigestErrorStatus.value = null
  workspaceDigestRefreshInflight = (async () => {
    try {
      const raw = await fetchOperatorDigest({ targetType: 'namespace' })
      operatorWorkspaceDigest.value = normalizeOperatorDigest(raw)
      lastWorkspaceDigestRefreshAt = Date.now()
    } catch (err) {
      const summary = extractApiError(err, 'operator 다이제스트 로드 실패')
      operatorDigestError.value = summary.message
      operatorDigestErrorStatus.value = summary.status
    } finally {
      operatorDigestLoading.value = false
      workspaceDigestRefreshInflight = null
    }
  })()
  return workspaceDigestRefreshInflight
}

export async function dispatchOperatorAction(request: OperatorActionRequest): Promise<OperatorActionResult> {
  operatorActionBusy.value = true
  operatorError.value = null
  operatorErrorStatus.value = null
  try {
    const result = await runOperatorAction(request)
    appendLog({
      actor: request.actor,
      action_type: request.action_type,
      target_label: targetLabelOf(request),
      outcome: result.confirm_required ? 'preview' : 'executed',
      message: logMessageFromResult(result),
      tool_name: result.tool_name,
    })
    await refreshOperatorSnapshot({ force: true })
    await refreshOperatorWorkspaceDigest({ force: true })
    return result
  } catch (err) {
    const summary = extractApiError(err, 'operator 액션 실패')
    const message = summary.message
    operatorError.value = message
    operatorErrorStatus.value = summary.status
    appendLog({
      actor: request.actor,
      action_type: request.action_type,
      target_label: targetLabelOf(request),
      outcome: 'error',
      message,
    })
    throw err
  } finally {
    operatorActionBusy.value = false
  }
}

export async function confirmOperatorPendingAction(
  actor: string,
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
): Promise<OperatorActionResult> {
  operatorActionBusy.value = true
  operatorError.value = null
  operatorErrorStatus.value = null
  try {
    const result = await confirmOperatorAction(actor, confirmToken, decision)
    appendLog({
      actor,
      action_type: decision,
      target_label: confirmToken,
      outcome: 'confirmed',
      message: logMessageFromResult(result),
      tool_name: result.tool_name,
    })
    await refreshOperatorSnapshot({ force: true })
    await refreshOperatorWorkspaceDigest({ force: true })
    return result
  } catch (err) {
    const summary = extractApiError(err, 'operator 확인 실패')
    const message = summary.message
    operatorError.value = message
    operatorErrorStatus.value = summary.status
    appendLog({
      actor,
      action_type: decision,
      target_label: confirmToken,
      outcome: 'error',
      message,
    })
    throw err
  } finally {
    operatorActionBusy.value = false
  }
}

registerOperatorRefresh(() => {
  void refreshOperatorSnapshot()
  void refreshOperatorWorkspaceDigest()
})
