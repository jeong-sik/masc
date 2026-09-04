export type KeeperChatDeliveryKey =
  | { readonly kind: 'operation'; readonly operation_id: string }
  | { readonly kind: 'fusion_run'; readonly request_id: string }
  | { readonly kind: 'workspace_message'; readonly request_id: string }
  | { readonly kind: 'approval_lifecycle'; readonly approval_id: string }

export type KeeperChatTranscriptSlot =
  | { readonly kind: 'accepted_user' }
  | { readonly kind: 'terminal_assistant' }
  | { readonly kind: 'approval_request' }
  | { readonly kind: 'approval_resolution' }
  | { readonly kind: 'approval_replay' }
  | { readonly kind: 'approval_replay_correction' }
  | { readonly kind: 'approval_continuation' }
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
  slot: 'accepted_user' | 'terminal_assistant',
): KeeperChatDeliveryProvenance {
  return {
    delivery_key: { kind: 'operation', operation_id: operationId },
    transcript_slot: { kind: slot },
  }
}

export function newKeeperChatOperationId(): string {
  return `kmsg-${crypto.randomUUID()}`
}

export function toolCallDeliveryProvenance(
  parent: KeeperChatDeliveryProvenance | null | undefined,
  executionId: string,
  ordinal: number,
): KeeperChatDeliveryProvenance | null {
  if (!parent) return null
  return {
    delivery_key: parent.delivery_key,
    transcript_slot: {
      kind: 'tool_call',
      execution_id: executionId,
      ordinal,
    },
  }
}

export function toolDeliveryProvenance(
  parent: KeeperChatDeliveryProvenance | null | undefined,
  ordinal: number,
): KeeperChatDeliveryProvenance | null {
  if (!parent) return null
  return {
    delivery_key: parent.delivery_key,
    transcript_slot: { kind: 'tool_delivery', ordinal },
  }
}

function sameDeliveryKey(left: KeeperChatDeliveryKey, right: KeeperChatDeliveryKey): boolean {
  if (left.kind !== right.kind) return false
  switch (left.kind) {
    case 'operation':
      return right.kind === 'operation' && left.operation_id === right.operation_id
    case 'fusion_run':
      return right.kind === 'fusion_run' && left.request_id === right.request_id
    case 'workspace_message':
      return right.kind === 'workspace_message' && left.request_id === right.request_id
    case 'approval_lifecycle':
      return right.kind === 'approval_lifecycle' && left.approval_id === right.approval_id
  }
}

function sameTranscriptSlot(
  left: KeeperChatTranscriptSlot,
  right: KeeperChatTranscriptSlot,
): boolean {
  if (left.kind !== right.kind) return false
  switch (left.kind) {
    case 'accepted_user':
    case 'terminal_assistant':
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
  slot: 'accepted_user' | 'terminal_assistant',
): boolean {
  return provenance != null
    && sameDeliveryProvenance(provenance, operationDeliveryProvenance(operationId, slot))
}
