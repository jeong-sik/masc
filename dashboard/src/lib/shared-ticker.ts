// Refcounted shared interval factory.
//
// Both `now-signal.ts` (5 s wall-clock for elapsed-duration displays)
// and `components/common/time-ago.ts` (30 s relative-clock for
// `<TimeAgo />`) had near-identical boilerplate: a module-level
// `signal<number>`, a `setInterval` armed on first consumer mount,
// cleared on last unmount, plus the two helper functions and the SSR
// `typeof window === 'undefined'` guard.  This factory captures that
// shape once so both files are ~10 LOC instead of ~25 each.
//
// Returns a `signal` (callers `.value` it from render) and a `use()`
// hook (callers call it from a component to participate in refcounting).
// Behaviour is byte-for-byte the same as the prior hand-rolled versions:
// SSR no-op, lazy start, refcount can never go negative.

import { signal, type Signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'

export interface SharedTicker {
  signal: Signal<number>
  use: () => void
}

export function createSharedTicker(
  intervalMs: number,
  initialValue: () => number = () => Date.now(),
): SharedTicker {
  const sig = signal(initialValue())
  let timerId: number | null = null
  let consumerCount = 0

  function start(): void {
    if (timerId != null) return
    if (typeof window === 'undefined') return
    timerId = window.setInterval(() => {
      sig.value = initialValue()
    }, intervalMs)
  }

  function stop(): void {
    if (timerId == null) return
    if (typeof window === 'undefined') return
    window.clearInterval(timerId)
    timerId = null
  }

  function use(): void {
    useEffect(() => {
      consumerCount += 1
      start()
      return () => {
        consumerCount = Math.max(0, consumerCount - 1)
        if (consumerCount === 0) stop()
      }
    }, [])
  }

  return { signal: sig, use }
}
