import {
  extractApiError,
  runOperatorAction,
} from './api/core'
import type {
  OperatorActionLogEntry,
  OperatorActionRequest,
  OperatorActionResult,
} from './types'
import { registerOperatorRefresh } from './sse-store'
import { UNKNOWN_STATUS_LABEL } from './lib/format-string'
import {
  operatorError,
  operatorErrorStatus,
  operatorActionBusy,
  operatorActionLog,
} from './operator-signals'
import { refreshOperatorWorkspaceDigest } from './operator-digest-observation'
import { refreshOperatorSnapshot } from './operator-snapshot-observation'
export { refreshOperatorSnapshot } from './operator-snapshot-observation'
export { refreshOperatorWorkspaceDigest } from './operator-digest-observation'

let nextLogId = 1

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

type ActionRefreshOptions = { refresh?: 'await' | 'background' }

async function refreshAfterAction(options: ActionRefreshOptions): Promise<void> {
  const refreshed = Promise.all([
    refreshOperatorSnapshot({ force: true }),
    refreshOperatorWorkspaceDigest({ force: true }),
  ])
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
    await refreshAfterAction(options)
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

registerOperatorRefresh(() => {
  void refreshOperatorSnapshot({ force: true })
  void refreshOperatorWorkspaceDigest()
})
