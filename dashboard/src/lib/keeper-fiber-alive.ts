// Typed fiber-alive decision for a keeper.
//
// Background: `keeper-detail-runtime.ts` derived `fiberAlive` from a
// 4-fallback chain that mixed four *semantically distinct* signals:
//
//   composite?.phase_diagnosis?.conditions.fiber_alive
//   ?? keeper.keepalive_running
//   ?? keeper.presence_keepalive
//   ?? (linkedState !== 'offline')
//
// Each signal answers a slightly different question:
//   1. composite truth         — "what did the observer record?"
//   2. keepalive_running       — "is the keepalive thread alive?"
//   3. presence_keepalive      — "did the presence ping arrive?"
//   4. link-state inference    — "do we even believe the keeper exists?"
//
// Collapsing them into one OR-chain loses provenance: when the dashboard
// shows "fiber alive" or "fiber dead", an operator cannot trace which
// source produced the verdict. This module returns the verdict *and*
// its source so downstream UI / debug surfaces can disambiguate.

import type { Keeper } from '../types'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'

export type FiberAliveSource =
  | 'composite_phase_diagnosis'
  | 'keepalive_running'
  | 'presence_keepalive'
  | 'link_state_inference'

export interface FiberAliveDecision {
  readonly alive: boolean
  readonly source: FiberAliveSource
}

interface FiberAliveInput {
  readonly keeper: Pick<Keeper, 'keepalive_running' | 'presence_keepalive'>
  readonly composite: KeeperCompositeSnapshot | null
  /** Result of `linkedRuntimeState(keeper)` — a string state ('offline'
   *  or other). Pass through as-is; this module only checks the
   *  offline sentinel to inform the lowest-priority fallback. */
  readonly linkedState: string
}

export function deriveFiberAlive({
  keeper,
  composite,
  linkedState,
}: FiberAliveInput): FiberAliveDecision {
  const fromComposite = composite?.phase_diagnosis?.conditions.fiber_alive
  if (typeof fromComposite === 'boolean') {
    return { alive: fromComposite, source: 'composite_phase_diagnosis' }
  }
  if (typeof keeper.keepalive_running === 'boolean') {
    return { alive: keeper.keepalive_running, source: 'keepalive_running' }
  }
  if (typeof keeper.presence_keepalive === 'boolean') {
    return { alive: keeper.presence_keepalive, source: 'presence_keepalive' }
  }
  return { alive: linkedState !== 'offline', source: 'link_state_inference' }
}
