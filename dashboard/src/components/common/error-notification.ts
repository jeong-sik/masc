// Error notification action handler — dedup + toast integration.

import { showToast } from './toast'
import type { DashboardError, ErrorCode } from '../../types/error'
import { classifyErrorCode, severityForCode } from '../../types/error'
import {
  errors,
  unacknowledgedErrors,
  unacknowledgedCount,
  acknowledgeError,
  clearAllErrors,
  startErrorCleanup,
  stopErrorCleanup,
} from './error-notification-state'

const DEDUP_WINDOW_MS = 5 * 60 * 1000 // 5 minutes

let _nextId = 0

function generateFingerprint(agentName: string, message: string): string {
  return `${agentName}:${message.slice(0, 100)}`
}

export function handleAgentFailed(params: {
  agentName: string
  taskId?: string
  errorCode?: ErrorCode
  error: string
}): void {
  const { agentName, taskId, error } = params
  const errorCode = params.errorCode ?? classifyErrorCode(error)
  const severity = severityForCode(errorCode)
  const fingerprint = generateFingerprint(agentName, error)
  const now = Date.now()

  const existing = errors.value.find(
    e => e.fingerprint === fingerprint && !e.acknowledged,
  )

  if (existing) {
    if (now - existing.lastSeen < DEDUP_WINDOW_MS) {
      errors.value = errors.value.map(e =>
        e.id === existing.id
          ? { ...e, count: e.count + 1, lastSeen: now }
          : e,
      )
      return
    }
    // Past dedup window — re-announce with fresh timestamp
    errors.value = errors.value.map(e =>
      e.id === existing.id
        ? { ...e, count: 1, timestamp: now, lastSeen: now }
        : e,
    )
    const taskLabel = taskId ? ` (${taskId})` : ''
    showToast(`${agentName}${taskLabel}: ${error}`, severity === 'info' ? 'warning' : 'error')
    return
  }

  const newError: DashboardError = {
    id: `err-${++_nextId}`,
    fingerprint,
    agentName,
    taskId: taskId ?? null,
    message: error,
    errorCode,
    severity,
    timestamp: now,
    acknowledged: false,
    count: 1,
    lastSeen: now,
  }

  errors.value = [...errors.value, newError]

  const taskLabel = taskId ? ` (${taskId})` : ''
  showToast(`${agentName}${taskLabel}: ${error}`, severity === 'info' ? 'warning' : 'error')
}

/** Test-only: reset error state. */
export function _testResetErrors(): void {
  errors.value = []
  _nextId = 0
}

export {
  errors,
  unacknowledgedErrors,
  unacknowledgedCount,
  acknowledgeError,
  clearAllErrors,
  startErrorCleanup,
  stopErrorCleanup,
}
