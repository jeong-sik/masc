import { signal } from '@preact/signals'

import { normalizeGoalLoopStatus, type GoalLoopStatusResponse } from './goal-loop-status'

// RFC-0284: goal-loop OODA status pushed over SSE — via the `goal_loop_status`
// live delta and the `goals` snapshot `loop` sub-field — so the panel renders
// from a shared store instead of polling on mount. Mirrors goal-tree-state.ts.
export const goalLoopStatusData = signal<GoalLoopStatusResponse | null>(null)
export const goalLoopStatusError = signal<string | null>(null)

// Hydrate from a raw goal-loop status payload (snake_case JSON as emitted by
// the server). Returns false — leaving the current value intact — when the
// payload is not a status object, so a stray empty/garbage delta cannot blank
// out a good snapshot. The server always stamps `schema_version`, so its
// presence is the cheap "this is a status" discriminator.
export function hydrateGoalLoopSnapshot(payload: unknown): boolean {
  if (!payload || typeof payload !== 'object') return false
  if (!('schema_version' in payload)) return false
  goalLoopStatusData.value = normalizeGoalLoopStatus(payload)
  goalLoopStatusError.value = null
  return true
}
