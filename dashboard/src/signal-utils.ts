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

/** Reconcile a keyed array and only assign when a key or value changed.
 *  Unchanged entries keep their previous references so row components do not
 *  rerender for API snapshots that are structurally identical fresh objects. */
export function setArrayByKeyIfChanged<T>(
  signal: Signal<T[]>,
  value: T[],
  keyFn: (item: T) => string | number,
  equalFn: (previous: T, next: T) => boolean = Object.is,
): void {
  const prev = signal.value
  let changed = prev.length !== value.length
  const reconciled: T[] = new Array(value.length)

  for (let index = 0; index < value.length; index += 1) {
    const nextItem = value[index]!
    if (index >= prev.length) {
      reconciled[index] = nextItem
      continue
    }

    const previousItem = prev[index]!
    if (keyFn(previousItem) !== keyFn(nextItem)) {
      changed = true
      reconciled[index] = nextItem
      continue
    }

    if (equalFn(previousItem, nextItem)) {
      reconciled[index] = previousItem
      continue
    }

    changed = true
    reconciled[index] = nextItem
  }

  if (changed) {
    signal.value = reconciled
  }
}
