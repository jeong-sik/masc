// The one place that decides what an SSE event type is.
//
// `SSEEventType` (types/sse.ts) already states two of these facts: it lists the
// `masc/`-prefixed twins as explicit members and carries `` `agent_core:${string}` ``
// as a template member for forward compatibility. Seven modules re-derived
// those facts by hand -- `sse.ts`, `sse-store.ts`, `schemas/sse.ts`,
// `schemas/sse-event-payload.ts`, `agent-core-runtime-store.ts` and
// `components/transport-health.ts` each spelled their own `startsWith`, and two
// of them did it inside the parse boundary that owns the union. The prefix
// `'masc/'` had two copies; `AGENT_CORE_EVENT_PREFIX` was read at six sites.
//
// A prefix test is the right shape for a template-literal member -- there is no
// enumeration to match against. What was wrong is that it happened seven times
// and threw the answer away each time. Here it happens once and the result is a
// narrowed type the caller keeps.

import { AGENT_CORE_EVENT_PREFIX, MASC_EVENT_PREFIX } from '../config/constants'

/** The forward-compatible member of `SSEEventType`. */
export type AgentCoreEventType = `agent_core:${string}`

export function isAgentCoreEventType(type: string): type is AgentCoreEventType {
  return type.startsWith(AGENT_CORE_EVENT_PREFIX)
}

/** The event's name without the `agent_core:` namespace, or the name unchanged.
 *  The payload parser looks its reader up by that suffix. */
export function agentCoreEventSuffix(type: string): string {
  return isAgentCoreEventType(type) ? type.slice(AGENT_CORE_EVENT_PREFIX.length) : type
}

/** The `masc/`-namespaced spelling of an event that also exists unprefixed. */
export type MascNamespacedEventType = `masc/${string}`

export function isMascNamespacedEventType(type: string): type is MascNamespacedEventType {
  return type.startsWith(MASC_EVENT_PREFIX)
}

/** The event's name without the `masc/` namespace, or the name unchanged. */
export function withoutMascNamespace(type: string): string {
  return isMascNamespacedEventType(type) ? type.slice(MASC_EVENT_PREFIX.length) : type
}

// The wire spells one family of events `task_*`, another `keeper_*`, a third
// `decision_*`, and each of those also appears under the `masc/` namespace.
// Three surfaces asked "which family is this" and each answered with its own
// pair of prefix tests.
export type SSEEventFamily = 'task' | 'keeper' | 'decision' | 'board' | 'other'

const FAMILY_BY_PREFIX: ReadonlyArray<readonly [string, SSEEventFamily]> = [
  ['task_', 'task'],
  ['keeper_', 'keeper'],
  ['decision_', 'decision'],
  ['board_', 'board'],
]

/** Which family the event belongs to, reading the `masc/` twin as the same
 *  family as its unprefixed name. */
export function sseEventFamily(type: string): SSEEventFamily {
  const name = withoutMascNamespace(type.trim())
  for (const [prefix, family] of FAMILY_BY_PREFIX) {
    if (name.startsWith(prefix)) return family
  }
  return 'other'
}
