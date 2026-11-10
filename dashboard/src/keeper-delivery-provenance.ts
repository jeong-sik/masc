export type KeeperChatDeliveryKey =
  | { readonly kind: 'operation'; readonly operation_id: string }
  | {
      readonly kind: 'operation_checkpoint'
      readonly operation_id: string
      readonly trace_id: string
      readonly turn_count: number
      readonly sha256: string
    }
  | {
      readonly kind: 'operation_native'
      readonly operation_id: string
      readonly continuation_id: string
    }
  | { readonly kind: 'fusion_run'; readonly request_id: string }
  | { readonly kind: 'workspace_message'; readonly request_id: string }
  | { readonly kind: 'connector_message'; readonly event_id: string }
  | { readonly kind: 'approval_lifecycle'; readonly approval_id: string }
  | { readonly kind: 'autonomous_turn'; readonly turn_ref: string }
  | {
      readonly kind: 'goal_notification'
      readonly goal_id: string
      readonly owner: string
      readonly event: string
    }

export interface KeeperApprovalInputBinding {
  readonly approval_id: string
  readonly input_fingerprint: string
}

export type KeeperChatTranscriptSlot =
  | { readonly kind: 'accepted_user' }
  | { readonly kind: 'terminal_result' }
  | { readonly kind: 'settled_failure' }
  | { readonly kind: 'approval_request' }
  | { readonly kind: 'approval_resolution' }
  | { readonly kind: 'approval_replay' }
  | { readonly kind: 'approval_replay_correction' }
  | { readonly kind: 'approval_continuation' }
  | { readonly kind: 'autonomous_input_binding'; readonly inputs: readonly KeeperApprovalInputBinding[] }
  | {
      readonly kind: 'tool_call'
      readonly execution_id: string
      readonly ordinal: number
    }
  | {
      readonly kind: 'tool_delivery'
      readonly ordinal: number
    }

export interface KeeperChatDeliveryProvenance {
  readonly delivery_key: KeeperChatDeliveryKey
  readonly transcript_slot: KeeperChatTranscriptSlot
}

export type KeeperChatDeliveryProvenanceDecode =
  | { status: 'absent'; value: null }
  | { status: 'invalid'; value: null }
  | { status: 'valid'; value: KeeperChatDeliveryProvenance }

export function operationDeliveryProvenance(
  operationId: string,
  slot: 'accepted_user' | 'terminal_result' | 'settled_failure',
): KeeperChatDeliveryProvenance {
  return {
    delivery_key: { kind: 'operation', operation_id: operationId },
    transcript_slot: { kind: slot },
  }
}

export function newKeeperChatOperationId(): string {
  return `kmsg-${crypto.randomUUID()}`
}

export function sameDeliveryKey(left: KeeperChatDeliveryKey, right: KeeperChatDeliveryKey): boolean {
  if (left.kind !== right.kind) return false
  switch (left.kind) {
    case 'operation':
      return right.kind === 'operation' && left.operation_id === right.operation_id
    case 'operation_checkpoint':
      return right.kind === 'operation_checkpoint'
        && left.operation_id === right.operation_id
        && left.trace_id === right.trace_id
        && left.turn_count === right.turn_count
        && left.sha256 === right.sha256
    case 'operation_native':
      return right.kind === 'operation_native'
        && left.operation_id === right.operation_id
        && left.continuation_id === right.continuation_id
    case 'fusion_run':
      return right.kind === 'fusion_run' && left.request_id === right.request_id
    case 'workspace_message':
      return right.kind === 'workspace_message' && left.request_id === right.request_id
    case 'connector_message':
      return right.kind === 'connector_message' && left.event_id === right.event_id
    case 'approval_lifecycle':
      return right.kind === 'approval_lifecycle' && left.approval_id === right.approval_id
    case 'autonomous_turn':
      return right.kind === 'autonomous_turn' && left.turn_ref === right.turn_ref
    case 'goal_notification':
      return right.kind === 'goal_notification'
        && left.goal_id === right.goal_id
        && left.owner === right.owner
        && left.event === right.event
  }
}

function sameTranscriptSlot(
  left: KeeperChatTranscriptSlot,
  right: KeeperChatTranscriptSlot,
): boolean {
  if (left.kind !== right.kind) return false
  switch (left.kind) {
    case 'accepted_user':
    case 'settled_failure':
    case 'terminal_result':
    case 'approval_request':
    case 'approval_resolution':
    case 'approval_replay':
    case 'approval_replay_correction':
    case 'approval_continuation':
      return true
    case 'tool_call':
      return right.kind === 'tool_call'
        && left.execution_id === right.execution_id
        && left.ordinal === right.ordinal
    case 'tool_delivery':
      return right.kind === 'tool_delivery' && left.ordinal === right.ordinal
    case 'autonomous_input_binding':
      return right.kind === 'autonomous_input_binding'
        && left.inputs.length === right.inputs.length
        && left.inputs.every((input, index) => input.approval_id === right.inputs[index]?.approval_id
          && input.input_fingerprint === right.inputs[index]?.input_fingerprint)
  }
}

export function sameDeliveryProvenance(
  left: KeeperChatDeliveryProvenance,
  right: KeeperChatDeliveryProvenance,
): boolean {
  return sameDeliveryKey(left.delivery_key, right.delivery_key)
    && sameTranscriptSlot(left.transcript_slot, right.transcript_slot)
}

export function isOperationDeliveryProvenance(
  provenance: KeeperChatDeliveryProvenance | null | undefined,
  operationId: string,
  slot: 'accepted_user' | 'terminal_result',
): boolean {
  return provenance != null
    && sameDeliveryProvenance(provenance, operationDeliveryProvenance(operationId, slot))
}

// The decoder lives here, without a schema library, because restored tool
// observations decode stored provenance synchronously while the dashboard
// starts. A library import here would put it in the initial chunk.
const REQUEST_ID_PATTERN = /^[A-Za-z0-9_.-]+$/
const TRACE_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/
const SHA256_PATTERN = /^[0-9a-f]{64}$/
// The goal_notification decoder refuses a field that OCaml's String.trim
// empties, and String.trim strips only these five characters.
const GOAL_FIELD_PATTERN = /[^ \f\n\r\t]/

function plainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const own = Object.keys(value)
  return own.length === keys.length && keys.every(key => Object.hasOwn(value, key))
}

function keeperRequestId(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 128
    && value !== '.' && value !== '..' && REQUEST_ID_PATTERN.test(value)
}

function nonNegativeSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

function goalNotificationField(value: unknown): value is string {
  return typeof value === 'string' && GOAL_FIELD_PATTERN.test(value)
}

// The backend publishes Ids.Turn_ref.to_string's final '#' and decimal
// ordinal. Keep the trace and ordinal opaque; do not coerce them to JS numbers.
function canonicalTurnRef(value: unknown): value is string {
  if (typeof value !== 'string') return false
  const separator = value.lastIndexOf('#')
  if (separator <= 0) return false
  const ordinal = value.slice(separator + 1)
  return ordinal !== '-0' && /^-?(?:0|[1-9][0-9]*)$/.test(ordinal)
}

// Mirrors delivery_key_to_yojson
// (lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml):
// one member per delivery_key constructor, with the same field names.
function decodeDeliveryKey(raw: unknown): KeeperChatDeliveryKey | null {
  if (!plainObject(raw)) return null
  switch (raw.kind) {
    case 'operation':
      return hasExactKeys(raw, ['kind', 'operation_id']) && keeperRequestId(raw.operation_id)
        ? { kind: 'operation', operation_id: raw.operation_id } : null
    case 'operation_checkpoint':
      // Keeper_id.Trace_id.of_string (lib/keeper_registry/keeper_id.ml:39) and
      // Keeper_checkpoint_ref.of_persisted, which accepts the lowercase hex
      // that Digestif.SHA256.to_hex prints.
      return hasExactKeys(raw, ['kind', 'operation_id', 'trace_id', 'turn_count', 'sha256'])
        && keeperRequestId(raw.operation_id)
        && typeof raw.trace_id === 'string' && TRACE_ID_PATTERN.test(raw.trace_id)
        && nonNegativeSafeInteger(raw.turn_count)
        && typeof raw.sha256 === 'string' && SHA256_PATTERN.test(raw.sha256)
        ? { kind: 'operation_checkpoint', operation_id: raw.operation_id, trace_id: raw.trace_id,
            turn_count: raw.turn_count, sha256: raw.sha256 } : null
    case 'operation_native':
      return hasExactKeys(raw, ['kind', 'operation_id', 'continuation_id'])
        && keeperRequestId(raw.operation_id) && keeperRequestId(raw.continuation_id)
        ? { kind: 'operation_native', operation_id: raw.operation_id, continuation_id: raw.continuation_id } : null
    case 'fusion_run':
    case 'workspace_message':
      return hasExactKeys(raw, ['kind', 'request_id']) && keeperRequestId(raw.request_id)
        ? { kind: raw.kind, request_id: raw.request_id } : null
    case 'connector_message':
      return hasExactKeys(raw, ['kind', 'event_id']) && keeperRequestId(raw.event_id)
        ? { kind: 'connector_message', event_id: raw.event_id } : null
    case 'approval_lifecycle':
      return hasExactKeys(raw, ['kind', 'approval_id']) && keeperRequestId(raw.approval_id)
        ? { kind: 'approval_lifecycle', approval_id: raw.approval_id } : null
    case 'autonomous_turn':
      return hasExactKeys(raw, ['kind', 'turn_ref']) && canonicalTurnRef(raw.turn_ref)
        ? { kind: 'autonomous_turn', turn_ref: raw.turn_ref } : null
    case 'goal_notification':
      return hasExactKeys(raw, ['kind', 'goal_id', 'owner', 'event'])
        && goalNotificationField(raw.goal_id) && goalNotificationField(raw.owner) && goalNotificationField(raw.event)
        ? { kind: 'goal_notification', goal_id: raw.goal_id, owner: raw.owner, event: raw.event } : null
    default:
      return null
  }
}

function decodeTranscriptSlot(raw: unknown): KeeperChatTranscriptSlot | null {
  if (!plainObject(raw)) return null
  switch (raw.kind) {
    case 'accepted_user':
    case 'settled_failure':
    case 'terminal_result':
    case 'approval_request':
    case 'approval_resolution':
    case 'approval_replay':
    case 'approval_replay_correction':
    case 'approval_continuation':
      return hasExactKeys(raw, ['kind']) ? { kind: raw.kind } : null
    case 'tool_call':
      return hasExactKeys(raw, ['kind', 'execution_id', 'ordinal'])
        && typeof raw.execution_id === 'string' && raw.execution_id.trim().length > 0
        && nonNegativeSafeInteger(raw.ordinal)
        ? { kind: 'tool_call', execution_id: raw.execution_id, ordinal: raw.ordinal } : null
    case 'tool_delivery':
      return hasExactKeys(raw, ['kind', 'ordinal']) && nonNegativeSafeInteger(raw.ordinal)
        ? { kind: 'tool_delivery', ordinal: raw.ordinal } : null
    case 'autonomous_input_binding': {
      if (!hasExactKeys(raw, ['kind', 'inputs']) || !Array.isArray(raw.inputs) || raw.inputs.length === 0) return null
      const inputs: KeeperApprovalInputBinding[] = []
      const approvals = new Set<string>()
      for (const input of raw.inputs) {
        if (!plainObject(input) || !hasExactKeys(input, ['approval_id', 'input_fingerprint'])
          || !keeperRequestId(input.approval_id) || typeof input.input_fingerprint !== 'string'
          || !SHA256_PATTERN.test(input.input_fingerprint) || approvals.has(input.approval_id)) return null
        approvals.add(input.approval_id)
        inputs.push({ approval_id: input.approval_id, input_fingerprint: input.input_fingerprint })
      }
      return { kind: 'autonomous_input_binding', inputs }
    }
    default:
      return null
  }
}

export function decodeKeeperChatDeliveryProvenance(
  deliveryKey: unknown,
  transcriptSlot: unknown,
): KeeperChatDeliveryProvenanceDecode {
  if (deliveryKey === undefined && transcriptSlot === undefined) {
    return { status: 'absent', value: null }
  }
  const delivery_key = decodeDeliveryKey(deliveryKey)
  const transcript_slot = decodeTranscriptSlot(transcriptSlot)
  if (delivery_key && transcript_slot) {
    if (transcript_slot.kind === 'autonomous_input_binding' && delivery_key.kind !== 'autonomous_turn') {
      return { status: 'invalid', value: null }
    }
    if (delivery_key.kind === 'autonomous_turn'
      && transcript_slot.kind !== 'autonomous_input_binding'
      && transcript_slot.kind !== 'tool_call' && transcript_slot.kind !== 'tool_delivery') {
      return { status: 'invalid', value: null }
    }
  }
  return delivery_key && transcript_slot
    ? { status: 'valid', value: { delivery_key, transcript_slot } }
    : { status: 'invalid', value: null }
}

/** An operation's continuation slots retain their exact storage key while
 * their live events are observed through that operation's journal. */
export function toolDeliveryBelongsToProducer(producer: KeeperChatDeliveryKey, stored: KeeperChatDeliveryKey): boolean {
  if (sameDeliveryKey(producer, stored)) return true
  return producer.kind === 'operation'
    && (stored.kind === 'operation_checkpoint' || stored.kind === 'operation_native')
    && producer.operation_id === stored.operation_id
}
