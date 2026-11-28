/**
 * What a keeper was told on its last assembled turn, as the server keeps it
 * (`Keeper_prompt_capture.to_json`, `GET /api/v1/keepers/:name/last-prompt`).
 *
 * The blocks come in assembly order. Each block id is one injection site of
 * the per-turn context (`Prompt_block_id`); the list is closed on the server,
 * so an id this screen does not know fails the decode instead of showing as
 * a generic block.
 */

import { Schema } from '../../lib/wire-schema'

/** `Prompt_block_id.to_string`, in declaration order. */
export const PROMPT_BLOCK_IDS = [
  'keeper_instructions',
  'dynamic_context',
  'active_goals',
  'direct_input_source',
  'completion_authority',
  'goals_awaiting_proof',
  'constitution_amendments',
  'temporal_summary',
  'memory_os_recall',
  'librarian_working_context',
  'recalled_memory',
  'recalled_memory_status',
  'operator_note',
  'skill_compositions',
  'arrived_stimuli',
] as const

const PromptBlockIdSchema = Schema.Literal(...PROMPT_BLOCK_IDS)

const PromptCaptureSchema = Schema.Struct({
  keeper: Schema.String,
  captured_at: Schema.Number,
  trace_id: Schema.String,
  absolute_turn: Schema.Int,
  blocks: Schema.Array(Schema.Struct({
    id: PromptBlockIdSchema,
    bytes: Schema.Int,
    text: Schema.String,
  })),
  assembled: Schema.NullOr(Schema.String),
  assembled_bytes: Schema.Int,
  system_prompt: Schema.NullOr(Schema.String),
})

export type PromptBlockId = (typeof PROMPT_BLOCK_IDS)[number]
export type PromptCapture = Schema.Schema.Type<typeof PromptCaptureSchema>
export type PromptBlock = PromptCapture['blocks'][number]

export const decodePromptCapture = Schema.decodeUnknownSync(PromptCaptureSchema)
