// Stream-contract construction and payload normalization for keeper
// conversation entries. Split out of keeper-state.ts: nothing here reads or
// writes a signal, and keeping the contract vocabulary in one file keeps the
// two normalize* switches next to the constructor they feed.

import { asString, asNumber, asStrictStringArray, withoutUndefined } from './lib/json-coerce'
import { isRecord } from './lib/type-guards'
import type {
  KeeperConversationStreamContract,
  KeeperConversationStreamContractSource,
  KeeperConversationStreamContractStatus,
} from './types'

export function keeperStreamContract(
  source: KeeperConversationStreamContractSource,
  status: KeeperConversationStreamContractStatus,
  opts: {
    eventName?: string | null
    requestId?: string | null
    turnRef?: string | null
    traceEventCount?: number | null
    lifecycleEvents?: string[] | null
    reason?: string | null
  } = {},
): KeeperConversationStreamContract {
  return withoutUndefined({
    source,
    status,
    eventName: opts.eventName ?? undefined,
    requestId: opts.requestId ?? undefined,
    turnRef: opts.turnRef ?? undefined,
    traceEventCount: opts.traceEventCount ?? undefined,
    lifecycleEvents: opts.lifecycleEvents ?? undefined,
    reason: opts.reason ?? undefined,
  })
}


function normalizeStreamContractSource(value: unknown): KeeperConversationStreamContractSource | null {
  switch (asString(value)?.trim()) {
    case 'keeper_chat_store':
      return 'keeper_chat_store'
    case 'backend_stream_lifecycle':
      return 'backend_stream_lifecycle'
    case 'backend_turn_trace':
      return 'backend_turn_trace'
    case 'rest_history':
      return 'rest_history'
    case 'sse_event':
      return 'sse_event'
    case 'client_operation_store':
      return 'client_operation_store'
    case 'client_operation_lookup':
      return 'client_operation_lookup'
    case 'client_local_send':
      return 'client_local_send'
    case 'client_stream_failure':
      return 'client_stream_failure'
    default:
      return null
  }
}

function normalizeStreamContractStatus(value: unknown): KeeperConversationStreamContractStatus | null {
  switch (asString(value)?.trim()) {
    case 'backend_stream_event':
      return 'backend_stream_event'
    case 'backend_terminal_event':
      return 'backend_terminal_event'
    case 'backend_lifecycle_replay':
      return 'backend_lifecycle_replay'
    case 'backend_trace_join':
      return 'backend_trace_join'
    case 'history_without_turn_ref':
      return 'history_without_turn_ref'
    case 'history_without_stream_events':
      return 'history_without_stream_events'
    case 'client_operation_terminal':
      return 'client_operation_terminal'
    case 'client_placeholder':
      return 'client_placeholder'
    case 'client_reconciled_history':
      return 'client_reconciled_history'
    case 'contract_gap':
      return 'contract_gap'
    default:
      return null
  }
}

export function normalizeStreamContract(raw: unknown): KeeperConversationStreamContract | null {
  if (!isRecord(raw)) return null
  const source = normalizeStreamContractSource(raw.source)
  const status = normalizeStreamContractStatus(raw.status)
  if (source === null || status === null) return null
  return keeperStreamContract(source, status, {
    eventName: asString(raw.event_name) ?? asString(raw.eventName) ?? null,
    requestId: asString(raw.request_id) ?? asString(raw.requestId) ?? null,
    turnRef: asString(raw.turn_ref) ?? asString(raw.turnRef) ?? null,
    traceEventCount: asNumber(raw.trace_event_count) ?? asNumber(raw.traceEventCount) ?? null,
    lifecycleEvents: asStrictStringArray(raw.lifecycle_events) ?? asStrictStringArray(raw.lifecycleEvents) ?? null,
    reason: asString(raw.reason) ?? null,
  })
}

