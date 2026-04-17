// Operator action result schema — schema-at-boundary for
// `POST /api/v1/operator/action` and `/api/v1/operator/confirm`.
//
// `status` is the only always-present field (backend contract).
// `confirm_required` / `confirm_token` drive the two-step confirm
// flow. `preview`, `result`, `executed_action`, `delegated_tool_result`
// are truly opaque — callers render them via JSON pretty-print without
// branching on shape, so they stay as `unknown()`.
//
// Uses the shared `SchemaDriftError` base landed in #7732.

import {
  boolean,
  object,
  optional,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

export const OperatorActionResultSchema = object({
  status: string(),
  confirm_required: optional(boolean()),
  confirm_token: optional(string()),
  preview: optional(unknown()),
  tool_name: optional(string()),
  result: optional(unknown()),
  /** @deprecated use `result`. Kept for backward compat during migration. */
  delegated_tool_result: optional(unknown()),
  executed_action: optional(unknown()),
})

export type OperatorActionResult = InferOutput<typeof OperatorActionResultSchema>

export class OperatorActionSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('operator-action', issues)
  }
}

export function parseOperatorActionResult(data: unknown): OperatorActionResult {
  return parseOrThrow(
    OperatorActionSchemaDriftError,
    OperatorActionResultSchema,
    data,
  )
}
