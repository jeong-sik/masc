// Error notification signal — dedup, toast integration, acknowledgment

import { signal, computed } from '@preact/signals'
import { showToast } from './toast'
import type { DashboardError } from '../../types/error'

const DEDUP_WINDOW_MS = 5 * 60 * 1000 // 5 minutes
const CLEANUP_INTERVAL_MS = 60 * 1000
const ACKNOWLEDGED_TTL_MS = 5 * 60 * 1000

export const errors = signal<DashboardError[]>([])
export const unacknowledgedErrors = computed(() =>
  errors.value.filter(e => !e.acknowledged),
)
export const unacknowledgedCount = computed(() => unacknowledgedErrors.value.length)

let _nextId = 0

function generateFingerprint(agentName: string, message: string): string {
  return `${agentName}:${message.slice(0, 100)}`
}

export function handleAgentFailed(params: {
  agentName: string
  taskId?: string
  error: string
}): void {
  const { agentName, taskId, error } = params
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
    showToast(`${agentName}${taskLabel}: ${error}`, 'error')
    return
  }

  const newError: DashboardError = {
    id: `err-${++_nextId}`,
    fingerprint,
    agentName,
    taskId: taskId ?? null,
    message: error,
    timestamp: now,
    acknowledged: false,
    count: 1,
    lastSeen: now,
  }

  errors.value = [...errors.value, newError]

  const taskLabel = taskId ? ` (${taskId})` : ''
  const countSuffix = existing ? ` [${existing.count + 1}회]` : ''
  showToast(`${agentName}${taskLabel}: ${error}${countSuffix}`, 'error')
}

export function acknowledgeError(id: string): void {
  errors.value = errors.value.map(e =>
    e.id === id ? { ...e, acknowledged: true } : e,
  )
}

export function clearAllErrors(): void {
  errors.value = errors.value.map(e => ({ ...e, acknowledged: true }))
}

/** Periodic cleanup — remove acknowledged errors older than TTL. */
let _cleanupTimer: ReturnType<typeof setInterval> | null = null

export function startErrorCleanup(): void {
  if (_cleanupTimer) return
  _cleanupTimer = setInterval(() => {
    const cutoff = Date.now() - ACKNOWLEDGED_TTL_MS
    const remaining = errors.value.filter(
      e => !e.acknowledged || e.lastSeen > cutoff,
    )
    if (remaining.length !== errors.value.length) {
      errors.value = remaining
    }
  }, CLEANUP_INTERVAL_MS)
}

export function stopErrorCleanup(): void {
  if (_cleanupTimer) {
    clearInterval(_cleanupTimer)
    _cleanupTimer = null
  }
}

/** Test-only: reset error state. */
export function _testResetErrors(): void {
  errors.value = []
  _nextId = 0
}
