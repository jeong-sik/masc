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

export const KeeperChatDeliveryKeySchema = Schema.Union(
  Schema.Struct({
    kind: Schema.Literal('operation'),
    operation_id: KeeperRequestIdSchema,
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
)

export const KeeperChatTranscriptSlotSchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('accepted_user') }),
  Schema.Struct({ kind: Schema.Literal('terminal_assistant') }),
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
