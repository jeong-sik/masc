/**
 * Canonical GoalPhase semantic tone classifier shared across Work and Pulse workspaces.
 */

export type CanonicalGoalPhase =
  | 'Executing'
  | 'Verifying'
  | 'Awaiting_confirmation'
  | 'Blocked'
  | 'Paused'
  | 'Completed'
  | 'Dropped'

export type GoalSemanticTone = 'ok' | 'info' | 'warn' | 'err' | 'stalled' | 'idle'

export function parseCanonicalGoalPhase(raw: string | null | undefined): CanonicalGoalPhase | null {
  if (!raw) return null
  switch (raw.trim().toLowerCase()) {
    case 'executing': return 'Executing'
    case 'verifying': return 'Verifying'
    case 'awaiting_confirmation': return 'Awaiting_confirmation'
    case 'blocked': return 'Blocked'
    case 'paused': return 'Paused'
    case 'completed': return 'Completed'
    case 'dropped': return 'Dropped'
    default: return null
  }
}

export function goalPhaseSemanticTone(phase: CanonicalGoalPhase): GoalSemanticTone {
  switch (phase) {
    case 'Executing': return 'info'
    case 'Verifying': return 'stalled'
    case 'Awaiting_confirmation': return 'warn'
    case 'Blocked': return 'err'
    case 'Paused': return 'idle'
    case 'Completed': return 'ok'
    case 'Dropped': return 'idle'
  }
}
