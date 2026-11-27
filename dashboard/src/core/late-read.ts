// When a screen should call a list "an earlier read".
//
// The read cache marks a value stale for as long as a re-read of it is out,
// and from the moment its topic changes until that re-read lands. On a live
// workspace that is about half a second every few seconds. A screen that
// shows a warning on `stale` alone flashes it with every re-read. These hooks
// hold the warning back until the value has stayed stale for a while.

import { useEffect, useState } from 'preact/hooks'
import type { Observed } from './resource-cache'

/** How long a value may stay stale before a screen says so. */
export const READ_LATE_AFTER_MS = 3_000

/** True once `on` has stayed true for `afterMs` without a break. */
export function useStayedTrue(on: boolean, afterMs: number): boolean {
  const [stayed, setStayed] = useState(false)
  useEffect(() => {
    if (!on) {
      setStayed(false)
      return
    }
    const timer = window.setTimeout(() => setStayed(true), afterMs)
    return () => window.clearTimeout(timer)
  }, [on, afterMs])
  return on && stayed
}

/** True once `observation` has been a stale value for `READ_LATE_AFTER_MS`. */
export function useLateRead(observation: Observed<unknown>): boolean {
  return useStayedTrue(observation.kind === 'value' && observation.stale, READ_LATE_AFTER_MS)
}
