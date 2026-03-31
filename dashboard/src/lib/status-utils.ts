// Status classification utilities for keeper/agent status strings.

/** True when the status indicates the process is not running (offline or inactive). */
export function isOfflineStatus(status: string | undefined | null): boolean {
  const s = (status ?? '').toLowerCase()
  return s === 'offline' || s === 'inactive'
}
