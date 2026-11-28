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

// `Keeper_context_assembly.system_prompt_receipt_to_json`: where each byte of
// the system prompt came from. A `block` span is a System observation the
// server put into the system prompt; the `existing_prefix` span is the
// keeper's base instructions, which the capture lists as `keeper_instructions`.
const SystemPromptSpanSchema = Schema.Struct({
  source: Schema.Union(
    Schema.Struct({ kind: Schema.Literal('block'), block: PromptBlockIdSchema }),
    Schema.Struct({ kind: Schema.Literal('unattributed'), reason: Schema.Literal('existing_prefix', 'separator') }),
  ),
  bytes: Schema.Int,
})

const SystemPromptPartitionSchema = Schema.Struct({
  carrier: Schema.Literal('system_prompt'),
  partition: Schema.Struct({
    bytes: Schema.Int,
    spans: Schema.Array(SystemPromptSpanSchema),
  }),
})

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
  system_prompt_partition: Schema.NullOr(SystemPromptPartitionSchema),
})

export type PromptBlockId = (typeof PROMPT_BLOCK_IDS)[number]
export type PromptCapture = Schema.Schema.Type<typeof PromptCaptureSchema>
export type PromptBlock = PromptCapture['blocks'][number]

const decodeCaptureShape = Schema.decodeUnknownSync(PromptCaptureSchema)

/**
 * The server writes a system prompt and its partition together, and refuses
 * a stored capture that has one without the other (`capture_of_json`).
 */
export function decodePromptCapture(input: unknown): PromptCapture {
  const capture = decodeCaptureShape(input)
  if ((capture.system_prompt === null) !== (capture.system_prompt_partition === null)) {
    throw new Error('last-prompt: system_prompt and system_prompt_partition must be present together')
  }
  return capture
}

/** Where a captured block went: into the system prompt, or the extra context. */
export type BlockDestination = 'system_prompt' | 'extra_context'

/**
 * The blocks the system prompt carries, read from its partition rather than
 * from a list kept here: the server decides which observations ride the
 * system prompt. Every other block is the extra context (`assembled`).
 */
export function systemPromptBlocks(capture: PromptCapture): ReadonlySet<PromptBlockId> {
  const partition = capture.system_prompt_partition
  if (partition === null) return new Set()
  const ids = new Set<PromptBlockId>()
  for (const span of partition.partition.spans) {
    if (span.source.kind === 'block') ids.add(span.source.block)
    else if (span.source.reason === 'existing_prefix') ids.add('keeper_instructions')
  }
  return ids
}
