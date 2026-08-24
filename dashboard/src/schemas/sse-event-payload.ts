// Typed boundary for Agent Core event payloads using atdgen-generated decoders.
//
// The SSE wire format wraps a typed payload inside an envelope
// (see lib/sse_event/sse_event.ml wrap_envelope).  This module parses the
// nested payload object with the atdts-generated readers in
// sse_event_generated.ts and returns a closed, discriminated union so
// downstream handlers never need string-key access on raw payload objects.
//
// Unknown event types and malformed payloads are rejected with a structured
// error; the caller decides whether to drop the event or fall back.

import { agentCoreEventSuffix } from '../lib/sse-event-type'
import { assertExhaustive } from '../lib/exhaustive'

import {
  readAgentCompletedPayload,
  readAgentFailedPayload,
  readAgentInputRequiredPayload,
  readAgentStartedPayload,
  readAgentYieldedPayload,
  readContentReplacementKeptPayload,
  readContentReplacementReplacedPayload,
  readContextCompactStartedPayload,
  readContextCompactedPayload,
  readHandoffCompletedPayload,
  readHandoffRequestedPayload,
  readSlotSchedulerObservedPayload,
  readToolCalledPayload,
  readToolCompletedPayload,
  readTurnCompletedPayload,
  readTurnReadyPayload,
  readTurnStartedPayload,
  type AgentCompletedPayload,
  type AgentFailedPayload,
  type AgentInputRequiredPayload,
  type AgentStartedPayload,
  type AgentYieldedPayload,
  type ContentReplacementKeptPayload,
  type ContentReplacementReplacedPayload,
  type ContextCompactStartedPayload,
  type ContextCompactedPayload,
  type HandoffCompletedPayload,
  type HandoffRequestedPayload,
  type SlotSchedulerObservedPayload,
  type ToolCalledPayload,
  type ToolCompletedPayload,
  type TurnCompletedPayload,
  type TurnReadyPayload,
  type TurnStartedPayload,
} from './sse_event_generated'

export type AgentCorePayloadParseIssue = {
  eventType: string
  message: string
}

export type AgentCorePayloadParseSuccess<T> = {
  success: true
  data: T
}

export type AgentCorePayloadParseFailure = {
  success: false
  error: { issues: AgentCorePayloadParseIssue[] }
}

export type AgentCorePayloadParseResult<T> =
  | AgentCorePayloadParseSuccess<T>
  | AgentCorePayloadParseFailure

/** Closed union of every Agent Core event payload the dashboard knows how to parse.
 *  New payload kinds are added here together with their atdgen reader. */
export type TypedAgentCorePayload =
  | { kind: 'agent_started'; payload: AgentStartedPayload }
  | { kind: 'agent_completed'; payload: AgentCompletedPayload }
  | { kind: 'agent_yielded'; payload: AgentYieldedPayload }
  | { kind: 'agent_input_required'; payload: AgentInputRequiredPayload }
  | { kind: 'agent_failed'; payload: AgentFailedPayload }
  | { kind: 'tool_called'; payload: ToolCalledPayload }
  | { kind: 'tool_completed'; payload: ToolCompletedPayload }
  | { kind: 'turn_started'; payload: TurnStartedPayload }
  | { kind: 'turn_completed'; payload: TurnCompletedPayload }
  | { kind: 'turn_ready'; payload: TurnReadyPayload }
  | { kind: 'handoff_requested'; payload: HandoffRequestedPayload }
  | { kind: 'handoff_completed'; payload: HandoffCompletedPayload }
  | { kind: 'context_compacted'; payload: ContextCompactedPayload }
  | { kind: 'context_compact_started'; payload: ContextCompactStartedPayload }
  | { kind: 'content_replacement_replaced'; payload: ContentReplacementReplacedPayload }
  | { kind: 'content_replacement_kept'; payload: ContentReplacementKeptPayload }
  | { kind: 'slot_scheduler_observed'; payload: SlotSchedulerObservedPayload }

/** Discriminant extracted from the closed union.  Keeping the kind literal in
 *  one place (the union above) eliminates the manual array/switch duplication
 *  that previously required touching three sites for every new payload kind. */
export type AgentCorePayloadKind = TypedAgentCorePayload['kind']

type PayloadReader<T> = (raw: unknown, context?: unknown) => T

type ReaderMap = {
  [K in AgentCorePayloadKind]: PayloadReader<Extract<TypedAgentCorePayload, { kind: K }>['payload']>
}

/** Exhaustive map from payload kind to its atdgen reader.  The mapped type
 *  guarantees every union member has a reader and that no stale kind lingers
 *  after the union changes. */
const READERS: ReaderMap = {
  agent_started: readAgentStartedPayload,
  agent_completed: readAgentCompletedPayload,
  agent_yielded: readAgentYieldedPayload,
  agent_input_required: readAgentInputRequiredPayload,
  agent_failed: readAgentFailedPayload,
  tool_called: readToolCalledPayload,
  tool_completed: readToolCompletedPayload,
  turn_started: readTurnStartedPayload,
  turn_completed: readTurnCompletedPayload,
  turn_ready: readTurnReadyPayload,
  handoff_requested: readHandoffRequestedPayload,
  handoff_completed: readHandoffCompletedPayload,
  context_compacted: readContextCompactedPayload,
  context_compact_started: readContextCompactStartedPayload,
  content_replacement_replaced: readContentReplacementReplacedPayload,
  content_replacement_kept: readContentReplacementKeptPayload,
  slot_scheduler_observed: readSlotSchedulerObservedPayload,
}

/** Runtime inventory derived from the reader keys.  The type assertion is
 *  safe because ReaderMap's keys are exactly AgentCorePayloadKind. */
export const AGENT_CORE_PAYLOAD_EVENT_TYPES = Object.keys(READERS) as readonly AgentCorePayloadKind[]

type AgentCorePayloadEventType = (typeof AGENT_CORE_PAYLOAD_EVENT_TYPES)[number]

function isAgentCorePayloadEventType(value: string): value is AgentCorePayloadEventType {
  return (AGENT_CORE_PAYLOAD_EVENT_TYPES as readonly string[]).includes(value)
}

function ok<T>(data: T): AgentCorePayloadParseSuccess<T> {
  return { success: true, data }
}

function fail(eventType: string, message: string): AgentCorePayloadParseFailure {
  return { success: false, error: { issues: [{ eventType, message }] } }
}

function tryRead<T>(
  eventType: string,
  reader: PayloadReader<T>,
  raw: unknown,
): AgentCorePayloadParseResult<T> {
  try {
    return ok(reader(raw, raw))
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return fail(eventType, message)
  }
}

function buildPayload<K extends AgentCorePayloadKind>(
  kind: K,
  payload: TypedAgentCorePayload['payload'],
): TypedAgentCorePayload {
  return { kind, payload } as unknown as TypedAgentCorePayload
}

/** Parse an Agent Core event payload into a typed, discriminated union.
 *  Returns a structured error if the event type is unknown or the payload
 *  fails atdgen validation. */
export function parseAgentCorePayload(
  eventType: string,
  raw: unknown,
): AgentCorePayloadParseResult<TypedAgentCorePayload> {
  const suffix = agentCoreEventSuffix(eventType)
  if (!isAgentCorePayloadEventType(suffix)) {
    return fail(eventType, `No typed payload reader for event type "${eventType}"`)
  }

  switch (suffix) {
    case 'context_compacted':
    case 'agent_started':
    case 'agent_completed':
    case 'agent_yielded':
    case 'agent_input_required':
    case 'agent_failed':
    case 'tool_called':
    case 'tool_completed':
    case 'turn_started':
    case 'turn_completed':
    case 'turn_ready':
    case 'handoff_requested':
    case 'handoff_completed':
    case 'context_compact_started':
    case 'content_replacement_replaced':
    case 'content_replacement_kept':
    case 'slot_scheduler_observed': {
      const result = tryRead(eventType, READERS[suffix] as PayloadReader<unknown>, raw)
      if (!result.success) return result
      return ok(buildPayload(suffix, result.data as TypedAgentCorePayload['payload']))
    }
  }
  return assertExhaustive(suffix, 'AgentCorePayloadKind')
}

/** Convenience wrapper that returns the typed payload or null.
 *  Use this when the caller intends to drop malformed events silently. */
export function parseAgentCorePayloadOrNull(
  eventType: string,
  raw: unknown,
): TypedAgentCorePayload | null {
  const result = parseAgentCorePayload(eventType, raw)
  return result.success ? result.data : null
}

/** Convenience wrapper that returns the typed payload or throws.
 *  Use this only when a parse failure should be treated as an unrecoverable
 *  invariant violation. */
export function parseAgentCorePayloadStrict(
  eventType: string,
  raw: unknown,
): TypedAgentCorePayload {
  const result = parseAgentCorePayload(eventType, raw)
  if (!result.success) {
    throw new SSEPayloadParseError(result.error.issues)
  }
  return result.data
}

export class SSEPayloadParseError extends Error {
  constructor(public readonly issues: readonly AgentCorePayloadParseIssue[]) {
    super(`SSE payload parse error: ${issues.map(i => i.message).join('; ')}`)
    this.name = 'SSEPayloadParseError'
  }
}
