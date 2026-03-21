// Signal update utilities — avoid unnecessary re-renders by skipping
// assignments when the value has not actually changed.

import type { Signal } from '@preact/signals'

/** Only update signal if the new value is referentially different. */
export function setIfChanged<T>(signal: Signal<T>, value: T): void {
  if (signal.value !== value) {
    signal.value = value
  }
}

/** Only update signal if the new array differs in length or boundary elements.
 *  Best for prepend-style buffers where elements are reused by reference. */
export function setArrayIfChanged<T>(
  signal: Signal<T[]>,
  value: T[],
): void {
  const prev = signal.value
  if (
    prev.length !== value.length
    || prev[0] !== value[0]
    || prev[prev.length - 1] !== value[value.length - 1]
  ) {
    signal.value = value
  }
}

/** Only update signal if the new array differs by length or boundary keys.
 *  Suitable for API-fetched arrays where each element is a fresh object
 *  but has a stable identity key (e.g., name, id). */
export function setArrayByKeyIfChanged<T>(
  signal: Signal<T[]>,
  value: T[],
  keyFn: (item: T) => string | number,
): void {
  const prev = signal.value
  if (prev.length !== value.length) {
    signal.value = value
    return
  }
  if (prev.length === 0) return
  const prevFirst = prev[0]
  const valFirst = value[0]
  const prevLast = prev[prev.length - 1]
  const valLast = value[value.length - 1]
  if (
    prevFirst == null || valFirst == null || prevLast == null || valLast == null
    || keyFn(prevFirst) !== keyFn(valFirst)
    || keyFn(prevLast) !== keyFn(valLast)
  ) {
    signal.value = value
  }
}
