import { signal } from '@preact/signals'

export const dashboardObserverConnected = signal(false)
export const dashboardObserverReady = signal(false)
export const dashboardObserverInstance = signal<string | null>(null)
export const dashboardObserverLastError = signal<string | null>(null)
export const dashboardObserverRejectedFrameCount = signal(0)
export const dashboardObserverLastRejectedFrameError = signal<string | null>(null)
export const dashboardObserverLastActivityAt = signal(0)
export const dashboardObserverIdleTimeoutMs = signal<number | null>(null)
export const dashboardObserverReconnectCount = signal(0)
export const dashboardObserverAdmissionCount = signal(0)
export const dashboardObserverLastDisconnectedAt = signal(0)
export const dashboardObserverLastEventAt = signal(0)
export const dashboardObserverEventCount60s = signal(0)

let hasReachedReady = false
const eventTimestamps: number[] = []

export function noteDashboardObserverReady(instance: string, idleTimeoutMs: number): void {
  dashboardObserverInstance.value = instance
  dashboardObserverIdleTimeoutMs.value = idleTimeoutMs
  dashboardObserverLastActivityAt.value = Date.now()
  dashboardObserverReady.value = true
  if (hasReachedReady) dashboardObserverReconnectCount.value++
  hasReachedReady = true
  dashboardObserverAdmissionCount.value++
}

export function noteDashboardObserverDisconnected(): void {
  dashboardObserverLastDisconnectedAt.value = Date.now()
}

/** Frame rejection is separate from stream failure: it cannot restart the
 * admitted connection or turn one malformed event into global HTTP recovery. */
export function noteDashboardObserverRejectedFrame(detail: string): void {
  dashboardObserverRejectedFrameCount.value++
  dashboardObserverLastRejectedFrameError.value = detail
}

export function noteDashboardObserverEvent(now: number = Date.now()): void {
  eventTimestamps.push(now)
  while (eventTimestamps.length && eventTimestamps[0]! < now - 60_000) eventTimestamps.shift()
  dashboardObserverLastEventAt.value = now
  dashboardObserverEventCount60s.value = eventTimestamps.length
}

export function _resetDashboardObserverCounterForTests(): void {
  hasReachedReady = false
  eventTimestamps.length = 0
  dashboardObserverConnected.value = false
  dashboardObserverReady.value = false
  dashboardObserverInstance.value = null
  dashboardObserverLastError.value = null
  dashboardObserverRejectedFrameCount.value = 0
  dashboardObserverLastRejectedFrameError.value = null
  dashboardObserverLastActivityAt.value = 0
  dashboardObserverIdleTimeoutMs.value = null
  dashboardObserverReconnectCount.value = 0
  dashboardObserverAdmissionCount.value = 0
  dashboardObserverLastDisconnectedAt.value = 0
  dashboardObserverLastEventAt.value = 0
  dashboardObserverEventCount60s.value = 0
}
