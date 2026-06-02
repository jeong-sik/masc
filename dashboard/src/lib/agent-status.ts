// RFC-0139 Phase 1 PR-1a — Agent status vocabulary SSOT.
//
// Typed closed sum + total parser + domain-specific predicates for
// dashboard agent presence. Keeps the keeper-status SSOT (lib/keeper-
// predicates.ts, RFC-0135) and the agent-status SSOT as parallel typed
// vocabularies; conversion between them happens at component boundaries
// only.
//
// No callsite migration in this PR — module + tests only. Migration to
// the predicates lands in RFC-0139 PR-1b/PR-1c.

import type { Agent } from '../types/core'

/** Closed sum of agent presence states. Mirrors the literal union on
 *  `Agent.status` in `dashboard/src/types/core.ts`. */
export type AgentStatus =
  | 'active'
  | 'busy'
  | 'listening'
  | 'idle'
  | 'inactive'
  | 'offline'

export const AGENT_STATUS_VALUES = [
  'active',
  'busy',
  'listening',
  'idle',
  'inactive',
  'offline',
] as const satisfies ReadonlyArray<AgentStatus>

const AGENT_STATUS_SET: ReadonlySet<string> = new Set(AGENT_STATUS_VALUES)

/** Total parser: raw string → typed AgentStatus, or null when the input
 *  is unknown / missing. Use at boundaries (wire decode, JSON parse). */
export function parseAgentStatus(raw: string | undefined | null): AgentStatus | null {
  if (raw == null) return null
  const lower = raw.toLowerCase()
  return AGENT_STATUS_SET.has(lower) ? (lower as AgentStatus) : null
}

/** True when the agent is not present (the backend has dropped the
 *  connection or the registry marked the slot dormant). Mirrors the
 *  cross-domain `isOfflineStatus` predicate scoped to *agent* tokens
 *  only — keeper-specific tokens like 'unbooted' / 'stopped' are
 *  rejected. */
export function isAgentOffline(agent: Pick<Agent, 'status'>): boolean {
  const parsed = parseAgentStatus(agent.status ?? null)
  return parsed === 'offline' || parsed === 'inactive'
}

/** True when the agent is actively driving work (taking turns, or
 *  consuming a tool). Distinct from "present" — listening / idle
 *  agents are present but not active. */
export function isAgentActive(agent: Pick<Agent, 'status'>): boolean {
  const parsed = parseAgentStatus(agent.status ?? null)
  return parsed === 'active' || parsed === 'busy'
}

/** True when the agent is reachable in any presence state (active,
 *  working, or just listening / idle). The negation of `isAgentOffline`
 *  for known tokens; unknown tokens return false. */
export function isAgentPresent(agent: Pick<Agent, 'status'>): boolean {
  const parsed = parseAgentStatus(agent.status ?? null)
  if (parsed == null) return false
  return parsed !== 'offline' && parsed !== 'inactive'
}
