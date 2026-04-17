/**
 * Keeper transitions schema — schema-at-boundary for
 * `GET /api/v1/keepers/:name/transitions`.
 *
 * Contract (see dashboard/docs/API_CONTRACT.md):
 * - Types derived via `InferOutput`; no hand-typed interface remains.
 * - `fetchKeeperTransitions` passes the response through
 *   `parseKeeperTransitionsResponse`. Shape drift raises
 *   `KeeperTransitionsSchemaDriftError` rather than leaving callers
 *   with `.transitions[0].new_phase` being `undefined`.
 * - Phase names and outcomes are left as open `string()` because the
 *   backend emits new values ahead of the dashboard; strict enums here
 *   would brick the strip / diagram during a backend-ahead deploy
 *   window. `selected_event` is `unknown()` since downstream already
 *   treats it opaquely for diagnostics.
 *
 * Rolled out as part of #7441 (P2 rollout) following pilot #7439.
 */

import {
  array,
  nullable,
  number,
  object,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

export const KeeperTransitionSchema = object({
  prev_phase: string(),
  new_phase: string(),
  selected_event: unknown(),
  wall_clock_at_decision: number(),
  transition_outcome: string(),
})

export const KeeperTransitionsResponseSchema = object({
  keeper: string(),
  current_phase: nullable(string()),
  count: number(),
  transitions: array(KeeperTransitionSchema),
})

export type KeeperTransition = InferOutput<typeof KeeperTransitionSchema>
export type KeeperTransitionsResponse = InferOutput<typeof KeeperTransitionsResponseSchema>

export class KeeperTransitionsSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .slice(0, 3)
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`keeper transitions schema drift: ${summary}`)
    this.name = 'KeeperTransitionsSchemaDriftError'
    this.issues = issues
  }
}

export function parseKeeperTransitionsResponse(
  data: unknown,
): KeeperTransitionsResponse {
  const result = safeParse(KeeperTransitionsResponseSchema, data)
  if (!result.success) {
    throw new KeeperTransitionsSchemaDriftError(result.issues)
  }
  return result.output
}
