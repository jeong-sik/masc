import { warmRetryDelayFor, WARM_RETRY_DELAYS_MS } from './warm-retry'

/** Retry only an owed failed read. A successful initializing envelope waits
 * for its producer; it never creates a status-read timer. */
export function createReadRecovery() {
  let phase: 'settled' | 'reading' | 'waiting' | 'failed' | 'refused' = 'settled'
  let active = true
  let revision = 0
  let delayStep = 0
  let timer: ReturnType<typeof setTimeout> | null = null
  let retry: (() => void) | null = null
  const clear = () => { if (timer !== null) clearTimeout(timer); timer = null }
  return {
    get revision() { return revision },
    get isReading() { return phase === 'reading' },
    started() { active = true; clear(); phase = 'reading' },
    waiting(read: () => void) { clear(); phase = 'waiting'; delayStep = 0; retry = read },
    succeeded() { revision += 1; clear(); phase = 'settled'; delayStep = 0; retry = null },
    failed(read: () => void, retryable = true) {
      if (!active) return
      clear()
      retry = read
      phase = retryable ? 'failed' : 'refused'
      if (!retryable) return
      delayStep = Math.min(delayStep + 1, WARM_RETRY_DELAYS_MS.length)
      timer = setTimeout(() => {
        timer = null
        if (active && phase === 'failed') retry?.()
      }, warmRetryDelayFor(delayStep))
    },
    recover(authorityChanged = false) {
      if (!active || (phase !== 'failed' && phase !== 'waiting' && !(authorityChanged && phase === 'refused'))) return
      clear()
      retry?.()
    },
    dispose() { active = false; revision += 1; clear(); retry = null; phase = 'settled' },
  }
}
