/**
 * The prompt catalog as the server sends it, and the answer to an override.
 *
 * - `GET /api/v1/prompts` lists every registered prompt
 *   (`Prompt_registry.prompts_json`). The server resolves which text is in
 *   force (`source`) and whether the prompt is one an operator writes
 *   (`operator_surface`); this module reads those words and decides neither.
 * - `POST /api/v1/prompts` with `set` or `clear` answers with the text now in
 *   force for that key.
 *
 * An unknown word fails the decode: a fourth source or a third surface is a
 * server change the screen has to learn, not a value to show as one it knows.
 */

import { PromptAuthoringIssuesSchema } from '../../api/schemas/prompt-authoring'
import { Schema } from '../../lib/wire-schema'

const PromptSourceSchema = Schema.Literal('override', 'file', 'missing')

/** `primary`: a prompt an operator writes whole. `fragment`: a piece the server fills into a larger text. */
const OperatorSurfaceSchema = Schema.Literal('primary', 'fragment')

const PromptEntrySchema = Schema.Struct({
  key: Schema.String,
  category: Schema.String,
  description: Schema.String,
  operator_surface: OperatorSurfaceSchema,
  source: PromptSourceSchema,
  effective: Schema.String,
  file_value: Schema.NullOr(Schema.String),
  override_value: Schema.NullOr(Schema.String),
  file_path: Schema.NullOr(Schema.String),
  /** The default this override replaced has changed since the override was saved. */
  override_default_moved: Schema.Boolean,
  required_file: Schema.Boolean,
  /** OCaml `String.length` of the text in force: bytes, not characters. */
  char_count: Schema.Int,
  template_variables: Schema.Array(Schema.String),
  authoring_issues: PromptAuthoringIssuesSchema,
})

/** An override saved on disk that this server process does not apply, and why. */
const HeldBackOverrideSchema = Schema.Struct({
  key: Schema.String,
  bytes: Schema.Int,
  reason: Schema.String,
})

const PromptCatalogSchema = Schema.Struct({
  prompts: Schema.Array(PromptEntrySchema),
  held_back: Schema.Array(HeldBackOverrideSchema),
})

const CuratorRefreshSchema = Schema.Union(
  Schema.Struct({ status: Schema.Literal('queued') }),
  Schema.Struct({ status: Schema.Literal('no_owner') }),
  Schema.Struct({ status: Schema.Literal('unavailable'), detail: Schema.String }),
)

const OverrideAppliedSchema = Schema.Struct({
  ok: Schema.Literal(true),
  message: Schema.String,
  key: Schema.String,
  source: PromptSourceSchema,
  effective: Schema.String,
  /** Present as a value only for a prompt the Workspace Memory curator reads. */
  curator_refresh: Schema.NullOr(CuratorRefreshSchema),
})

export type PromptSource = Schema.Schema.Type<typeof PromptSourceSchema>
export type OperatorSurface = Schema.Schema.Type<typeof OperatorSurfaceSchema>
export type PromptEntry = Schema.Schema.Type<typeof PromptEntrySchema>
export type HeldBackOverride = Schema.Schema.Type<typeof HeldBackOverrideSchema>
export type PromptCatalog = Schema.Schema.Type<typeof PromptCatalogSchema>
export type CuratorRefresh = Schema.Schema.Type<typeof CuratorRefreshSchema>
export type OverrideApplied = Schema.Schema.Type<typeof OverrideAppliedSchema>

export type PromptOverrideRequest =
  | { readonly action: 'set'; readonly key: string; readonly value: string }
  | { readonly action: 'clear'; readonly key: string }

export const decodePromptCatalog = Schema.decodeUnknownSync(PromptCatalogSchema)
export const decodeOverrideApplied = Schema.decodeUnknownSync(OverrideAppliedSchema)
