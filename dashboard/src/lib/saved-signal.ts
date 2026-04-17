import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import type { Signal } from '@preact/signals'

/**
 * `useSignal` variant that persists its value to `localStorage`.
 *
 * Semantics:
 *   - First mount reads the stored JSON value under `key` (if present and parseable)
 *     and assigns it to `signal.value`. If parsing fails or the key is absent, the
 *     signal keeps `initial`.
 *   - Every subsequent change writes the new value as JSON to `localStorage[key]`.
 *   - If the new value equals the empty string `''` or equals `initial` (via
 *     `Object.is` for primitives), the key is removed instead of written, keeping
 *     storage tidy.
 *   - Write/read failures (quota, malformed JSON, missing `window`) are caught
 *     and logged via `console.warn`; the in-memory signal continues to work.
 *
 * Returns the `Signal<T>` plus a `reset()` helper that clears the stored entry
 * and assigns `initial` back to the signal.
 *
 * Recommended key shape: `dash:filter:<component-tag>:<field>`.
 * Only intended for JSON-serializable values (string, number, boolean, plain
 * objects/arrays of the same).
 */
export function useSavedSignal<T>(key: string, initial: T): [Signal<T>, () => void] {
  const signal = useSignal<T>(initial)
  const hydrated = useRef(false)

  // Mount: read persisted value once (if any).
  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.localStorage === 'undefined') {
      hydrated.current = true
      return
    }
    try {
      const raw = window.localStorage.getItem(key)
      if (raw !== null) {
        const parsed = JSON.parse(raw) as T
        signal.value = parsed
      }
    } catch (err) {
      console.warn(`[useSavedSignal] failed to read "${key}":`, err)
    }
    hydrated.current = true
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])

  // Persist on change (after hydration to avoid writing the initial default).
  useEffect(() => {
    if (!hydrated.current) return
    if (typeof window === 'undefined' || typeof window.localStorage === 'undefined') return
    try {
      const value = signal.value
      const isEmpty = value === '' || Object.is(value, initial)
      if (isEmpty) {
        window.localStorage.removeItem(key)
        return
      }
      const encoded = JSON.stringify(value)
      const current = window.localStorage.getItem(key)
      if (current !== encoded) {
        window.localStorage.setItem(key, encoded)
      }
    } catch (err) {
      console.warn(`[useSavedSignal] failed to write "${key}":`, err)
    }
  }, [signal.value, key, initial, signal])

  const reset = () => {
    if (typeof window !== 'undefined' && typeof window.localStorage !== 'undefined') {
      try {
        window.localStorage.removeItem(key)
      } catch (err) {
        console.warn(`[useSavedSignal] failed to clear "${key}":`, err)
      }
    }
    signal.value = initial
  }

  return [signal, reset]
}
