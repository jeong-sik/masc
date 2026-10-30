// Signal update utilities — avoid unnecessary re-renders by skipping
// assignments when the value has not actually changed.

import type { Signal } from '@preact/signals'

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function stableValueEqual(left: unknown, right: unknown): boolean {
  if (Object.is(left, right)) return true
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) return false
    if (left.length !== right.length) return false
    return left.every((value, index) => stableValueEqual(value, right[index]))
  }
  if (isPlainRecord(left) || isPlainRecord(right)) {
    if (!isPlainRecord(left) || !isPlainRecord(right)) return false
    const keys = new Set([...Object.keys(left), ...Object.keys(right)])
    for (const key of keys) {
      if (!stableValueEqual(left[key], right[key])) return false
    }
    return true
  }
  return false
}

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
  equalFn: (previous: T, next: T) => boolean = stableValueEqual,
): void {
  const prev = signal.value
  let changed = prev.length !== value.length
  const reconciled: T[] = new Array(value.length)

  for (let index = 0; index < value.length; index += 1) {
    const nextItem = value[index]
    if (index >= prev.length) {
      reconciled[index] = nextItem as T
      continue
    }

    const previousItem = prev[index]
    if (previousItem == null || nextItem == null) {
      if (!Object.is(previousItem, nextItem)) changed = true
      reconciled[index] = nextItem as T
      continue
    }

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
