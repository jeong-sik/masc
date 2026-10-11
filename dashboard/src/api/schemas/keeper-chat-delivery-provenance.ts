import { check, literal, number, pipe, safeParse, strictObject, string, union } from 'valibot'

import type {
  KeeperChatDeliveryProvenance,
  KeeperChatDeliveryProvenanceDecode,
} from '../../keeper-delivery-provenance'

const NonNegativeIntegerSchema = pipe(number(), check(value => Number.isSafeInteger(value) && value >= 0))

const KeeperRequestIdSchema = pipe(
  string(),
  check(value => (
    value.length > 0
    && value.length <= 128
    && value !== '.'
    && value !== '..'
    && /^[A-Za-z0-9_.-]+$/.test(value)
  )),
)

const KeeperExecutionIdSchema = pipe(
  string(),
  check(value => value.trim().length > 0),
)

// Keeper_id.Trace_id.of_string (lib/keeper_registry/keeper_id.ml:39).
const KeeperTraceIdSchema = pipe(
  string(),
  check(value => /^[A-Za-z0-9_-]{1,64}$/.test(value)),
)

// Keeper_checkpoint_ref.of_persisted accepts only the lowercase hex that
// Digestif.SHA256.to_hex prints (lib/keeper_checkpoint_ref/keeper_checkpoint_ref.ml:48).
const CheckpointSha256Schema = pipe(
  string(),
  check(value => /^[0-9a-f]{64}$/.test(value)),
)

// The goal_notification decoder refuses a field that OCaml's String.trim
// empties, and String.trim strips only these five characters.
const GoalNotificationFieldSchema = pipe(
  string(),
  check(value => /[^ \f\n\r\t]/.test(value)),
)

// Mirrors delivery_key_to_yojson
// (lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml:96):
// one member per delivery_key constructor, with the same field names.
export const KeeperChatDeliveryKeySchema = union([
  strictObject({
    kind: literal('operation'),
    operation_id: KeeperRequestIdSchema,
  }),
  strictObject({
    kind: literal('operation_checkpoint'),
    operation_id: KeeperRequestIdSchema,
    trace_id: KeeperTraceIdSchema,
    turn_count: NonNegativeIntegerSchema,
    sha256: CheckpointSha256Schema,
  }),
  strictObject({
    kind: literal('operation_native'),
    operation_id: KeeperRequestIdSchema,
    continuation_id: KeeperRequestIdSchema,
  }),
  strictObject({
    kind: literal('fusion_run'),
    request_id: KeeperRequestIdSchema,
  }),
  strictObject({
    kind: literal('workspace_message'),
    request_id: KeeperRequestIdSchema,
  }),
  strictObject({
    kind: literal('approval_lifecycle'),
    approval_id: KeeperRequestIdSchema,
  }),
  strictObject({
    kind: literal('goal_notification'),
    goal_id: GoalNotificationFieldSchema,
    owner: GoalNotificationFieldSchema,
    event: GoalNotificationFieldSchema,
  }),
])

export const KeeperChatTranscriptSlotSchema = union([
  strictObject({ kind: literal('accepted_user') }),
  strictObject({ kind: literal('terminal_result') }),
  strictObject({ kind: literal('approval_request') }),
  strictObject({ kind: literal('approval_resolution') }),
  strictObject({ kind: literal('approval_replay') }),
  strictObject({ kind: literal('approval_replay_correction') }),
  strictObject({ kind: literal('approval_continuation') }),
  strictObject({
    kind: literal('tool_call'),
    execution_id: KeeperExecutionIdSchema,
    ordinal: NonNegativeIntegerSchema,
  }),
  strictObject({
    kind: literal('tool_delivery'),
    ordinal: NonNegativeIntegerSchema,
  }),
])

export const KeeperChatDeliveryProvenanceSchema = strictObject({
  delivery_key: KeeperChatDeliveryKeySchema,
  transcript_slot: KeeperChatTranscriptSlotSchema,
})

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
  const parsed = safeParse(KeeperChatDeliveryProvenanceSchema, {
    delivery_key: deliveryKey,
    transcript_slot: transcriptSlot,
  })
  return parsed.success
    ? { status: 'valid', value: parsed.output satisfies KeeperChatDeliveryProvenance }
    : { status: 'invalid', value: null }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Status history, REST history, SSE and stored observations share this closed
 * decoder. It uses the dashboard schema dependency without loading Effect into
 * the streaming or restoration paths. */
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
