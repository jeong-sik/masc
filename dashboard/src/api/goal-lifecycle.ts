export type GoalResumePhase = 'executing' | 'verifying' | 'awaiting_confirmation'

/** Suspensions require an explicit live restore state. No fabricated default. */
export function decodeGoalResumePhase(phase: string, raw: unknown): GoalResumePhase | null {
  if (phase === 'paused' || phase === 'blocked') {
    if (raw === 'executing' || raw === 'verifying' || raw === 'awaiting_confirmation') return raw
    throw new Error(`Goal ${phase} requires a valid resume_phase`)
  }
  if (raw != null) throw new Error('Only a suspended Goal may carry resume_phase')
  return null
}

export const GOAL_TRANSITION_LABELS = {
  request_complete: 'Request completion',
  drop: 'Drop',
  reopen: 'Reopen',
  pause: 'Pause',
  resume: 'Resume',
  block: 'Block',
  unblock: 'Unblock',
} as const
export type GoalTransitionAction = keyof typeof GOAL_TRANSITION_LABELS

/** The server FSM owns availability; this is only the public action vocabulary. */
export function goalLifecycleActions(nextActions: readonly string[]): GoalTransitionAction[] {
  return nextActions.filter((action): action is GoalTransitionAction =>
    Object.hasOwn(GOAL_TRANSITION_LABELS, action))
}
