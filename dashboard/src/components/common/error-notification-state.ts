import { signal, computed } from '@preact/signals'
import type { DashboardError } from '../../types/error'

const ACKNOWLEDGED_TTL_MS = 5 * 60 * 1000

export const errors = signal<DashboardError[]>([])
export const unacknowledgedErrors = computed(() =>
  errors.value.filter(e => !e.acknowledged),
)
export const unacknowledgedCount = computed(() => unacknowledgedErrors.value.length)

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
  }, 60 * 1000)
}

export function stopErrorCleanup(): void {
  if (_cleanupTimer) {
    clearInterval(_cleanupTimer)
    _cleanupTimer = null
  }
}
