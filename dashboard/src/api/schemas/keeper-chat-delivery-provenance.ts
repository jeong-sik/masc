import { Either, Schema } from 'effect'

import type {
  KeeperChatDeliveryProvenance,
  KeeperChatDeliveryProvenanceDecode,
} from '../../keeper-delivery-provenance'

const KeeperRequestIdSchema = Schema.String.pipe(
  Schema.filter(value => (
    value.length > 0
    && value.length <= 128
    && value !== '.'
    && value !== '..'
    && /^[A-Za-z0-9_.-]+$/.test(value)
  ) || 'invalid Keeper request id'),
)

const KeeperExecutionIdSchema = Schema.String.pipe(
  Schema.filter(value => value.trim().length > 0 || 'tool execution id must not be blank'),
)

// Keeper_id.Trace_id.of_string (lib/keeper_registry/keeper_id.ml:39).
const KeeperTraceIdSchema = Schema.String.pipe(
  Schema.filter(value => /^[A-Za-z0-9_-]{1,64}$/.test(value) || 'invalid Keeper trace id'),
)

// Keeper_checkpoint_ref.of_persisted accepts only the lowercase hex that
// Digestif.SHA256.to_hex prints (lib/keeper_checkpoint_ref/keeper_checkpoint_ref.ml:48).
const CheckpointSha256Schema = Schema.String.pipe(
  Schema.filter(value => /^[0-9a-f]{64}$/.test(value) || 'invalid checkpoint sha256'),
)

// The goal_notification decoder refuses a field that OCaml's String.trim
// empties, and String.trim strips only these five characters.
const GoalNotificationFieldSchema = Schema.String.pipe(
  Schema.filter(value => /[^ \f\n\r\t]/.test(value) || 'goal notification field must not be blank'),
)

// Mirrors delivery_key_to_yojson
// (lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml:96):
// one member per delivery_key constructor, with the same field names.
export const KeeperChatDeliveryKeySchema = Schema.Union(
  Schema.Struct({
    kind: Schema.Literal('operation'),
    operation_id: KeeperRequestIdSchema,
  }),
  Schema.Struct({
    kind: Schema.Literal('operation_checkpoint'),
    operation_id: KeeperRequestIdSchema,
    trace_id: KeeperTraceIdSchema,
    turn_count: Schema.NonNegativeInt,
    sha256: CheckpointSha256Schema,
  }),
  Schema.Struct({
    kind: Schema.Literal('operation_native'),
    operation_id: KeeperRequestIdSchema,
    continuation_id: KeeperRequestIdSchema,
  }),
  Schema.Struct({
    kind: Schema.Literal('fusion_run'),
    request_id: KeeperRequestIdSchema,
  }),
  Schema.Struct({
    kind: Schema.Literal('workspace_message'),
    request_id: KeeperRequestIdSchema,
  }),
  Schema.Struct({
    kind: Schema.Literal('approval_lifecycle'),
    approval_id: KeeperRequestIdSchema,
  }),
  Schema.Struct({
    kind: Schema.Literal('goal_notification'),
    goal_id: GoalNotificationFieldSchema,
    owner: GoalNotificationFieldSchema,
    event: GoalNotificationFieldSchema,
  }),
)

export const KeeperChatTranscriptSlotSchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('accepted_user') }),
  Schema.Struct({ kind: Schema.Literal('terminal_result') }),
  Schema.Struct({ kind: Schema.Literal('approval_request') }),
  Schema.Struct({ kind: Schema.Literal('approval_resolution') }),
  Schema.Struct({ kind: Schema.Literal('approval_replay') }),
  Schema.Struct({ kind: Schema.Literal('approval_replay_correction') }),
  Schema.Struct({ kind: Schema.Literal('approval_continuation') }),
  Schema.Struct({
    kind: Schema.Literal('tool_call'),
    execution_id: KeeperExecutionIdSchema,
    ordinal: Schema.NonNegativeInt,
  }),
  Schema.Struct({
    kind: Schema.Literal('tool_delivery'),
    ordinal: Schema.NonNegativeInt,
  }),
)

export const KeeperChatDeliveryProvenanceSchema = Schema.Struct({
  delivery_key: KeeperChatDeliveryKeySchema,
  transcript_slot: KeeperChatTranscriptSlotSchema,
})

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

export function decodeKeeperChatDeliveryProvenance(
  deliveryKey: unknown,
  transcriptSlot: unknown,
): KeeperChatDeliveryProvenanceDecode {
  if (deliveryKey === undefined && transcriptSlot === undefined) {
    return { status: 'absent', value: null }
  }
  if (deliveryKey === undefined || transcriptSlot === undefined) {
    return { status: 'invalid', value: null }
  }
  const parsed = Schema.decodeUnknownEither(
    KeeperChatDeliveryProvenanceSchema,
    STRICT_PARSE_OPTIONS,
  )({ delivery_key: deliveryKey, transcript_slot: transcriptSlot })
  return Either.isRight(parsed)
    ? { status: 'valid', value: parsed.right as KeeperChatDeliveryProvenance }
    : { status: 'invalid', value: null }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Decode status-tool history rows at the same lazy Effect boundary as the
 * REST chat-history endpoint. The UI state module only consumes this canonical
 * projection, keeping Effect out of the initial dashboard chunk. */
export function normalizeKeeperStatusPayloadDeliveryProvenance(data: unknown): unknown {
  if (!isRecord(data) || !Array.isArray(data.history_tail)) return data
  return {
    ...data,
    history_tail: data.history_tail.map((raw) => {
      if (!isRecord(raw)) return raw
      const { delivery_key, transcript_slot, ...message } = raw
      const provenance = decodeKeeperChatDeliveryProvenance(delivery_key, transcript_slot)
      return {
        ...message,
        delivery_provenance: provenance.value,
        delivery_provenance_status: provenance.status,
      }
    }),
  }
}
