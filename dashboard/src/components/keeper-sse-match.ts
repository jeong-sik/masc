import type { SSEEvent } from '../types'
import { normalizeSSEDispatchType } from '../sse'
import { canonicalKeeperName } from './common/keeper-identity'

function normalizeMatchKey(value: string | null | undefined): string {
  return (value ?? '').trim().toLowerCase()
}

export function sseKeeperName(event: SSEEvent): string {
  return canonicalKeeperName(
    event.name
      ?? event.keeper_name
      ?? event.agent_name
      ?? event.agent,
  ) ?? ''
}

export function sseEventMatchesKeeper(event: SSEEvent, keeperName: string): boolean {
  const eventKeeper = normalizeMatchKey(sseKeeperName(event))
  const targetKeeper = normalizeMatchKey(canonicalKeeperName(keeperName) ?? keeperName)
  return eventKeeper !== '' && eventKeeper === targetKeeper
}

export function isKeeperToolActivityEvent(event: SSEEvent): boolean {
  return normalizeSSEDispatchType(event.type) === 'keeper_tool_call'
}

export function isKeeperToolEvidenceCommittedEvent(event: SSEEvent): boolean {
  return event.type === 'keeper_tool_call_evidence_committed'
}
