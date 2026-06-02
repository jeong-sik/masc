// Runtime context-ratio thresholds — populated from /api/v1/dashboard/config.
// Consumers should import from here; constants.ts values are fallback defaults only.

import { signal, computed, type ReadonlySignal } from '@preact/signals'
import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_WARN, CONTEXT_RATIO_COMPACTING } from './constants'

export interface ContextThresholds {
  critical: number
  warn: number
  compacting: number
}

const _thresholds = signal<ContextThresholds>({
  critical: CONTEXT_RATIO_CRITICAL,
  warn: CONTEXT_RATIO_WARN,
  compacting: CONTEXT_RATIO_COMPACTING,
})

/** Mutable ref for the writer (app.ts init).  Consumers read via `contextThresholds`. */
export function setContextThresholds(next: ContextThresholds): void {
  _thresholds.value = next
}

/** Readonly signal of the current runtime thresholds. */
export const contextThresholds: ReadonlySignal<ContextThresholds> = computed(() => _thresholds.value)
