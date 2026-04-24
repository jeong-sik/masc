// Phase names and outcomes are kept open (`string()`) because the
// backend ships new phase variants ahead of the dashboard. A strict
// `picklist` here would brick the transition strip and state diagram
// during a backend-ahead deploy window.
// `selected_event` stays `unknown()` — callers render it opaquely for
// diagnostics and never branch on its shape.

import {
  array,
  boolean,
  nullable,
  number,
  object,
  optional,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

const KeeperTransitionOperatorSignalSchema = object({
  class: string(),
  severity: string(),
  requires_operator_decision: boolean(),
  next_human_action: nullable(string()),
  summary: string(),
})

const KeeperTransitionSchema = object({
  prev_phase: string(),
  new_phase: string(),
  selected_event: unknown(),
  event_type: optional(string()),
  wall_clock_at_decision: number(),
  transition_outcome: string(),
  operator_signal: optional(KeeperTransitionOperatorSignalSchema),
})

const KeeperTransitionsResponseSchema = object({
  keeper: string(),
  current_phase: nullable(string()),
  count: number(),
  transitions: array(KeeperTransitionSchema),
})

export type KeeperTransition = InferOutput<typeof KeeperTransitionSchema>
export type KeeperTransitionOperatorSignal = InferOutput<
  typeof KeeperTransitionOperatorSignalSchema
>
export type KeeperTransitionsResponse = InferOutput<typeof KeeperTransitionsResponseSchema>

export class KeeperTransitionsSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`keeper transitions schema drift: ${summary}`)
    this.name = KeeperTransitionsSchemaDriftError.name
    this.issues = issues
  }
}

export function parseKeeperTransitionsResponse(
  data: unknown,
): KeeperTransitionsResponse {
  // abortEarly bounds both the parse cost and the retained `issues`
  // array on thrown errors — a 30-transition total-drift payload would
  // otherwise pin ~150 issue objects per error instance.
  const result = safeParse(KeeperTransitionsResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new KeeperTransitionsSchemaDriftError(result.issues)
  }
  return result.output
}
