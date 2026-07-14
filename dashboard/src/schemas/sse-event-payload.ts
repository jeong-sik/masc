// Typed boundary for OAS event payloads using atdgen-generated decoders.
//
// The SSE wire format wraps a typed payload inside an envelope
// (see lib/sse_event/sse_event.ml wrap_envelope).  This module parses the
// nested payload object with the atdts-generated readers in
// sse_event_generated.ts and returns a closed, discriminated union so
// downstream handlers never need string-key access on raw payload objects.
//
// Unknown event types and malformed payloads are rejected with a structured
// error; the caller decides whether to drop the event or fall back.

import { OAS_EVENT_PREFIX } from '../config/constants'
import { assertExhaustive } from '../lib/exhaustive'

import {
  readAgentCompletedPayload,
  readAgentFailedPayload,
  readAgentStartedPayload,
  readHandoffCompletedPayload,
  readHandoffRequestedPayload,
  readToolCalledPayload,
  readToolCompletedPayload,
  readTurnCompletedPayload,
  readTurnReadyPayload,
  readTurnStartedPayload,
  type AgentCompletedPayload,
  type AgentFailedPayload,
  type AgentStartedPayload,
  type HandoffCompletedPayload,
  type HandoffRequestedPayload,
  type ToolCalledPayload,
  type ToolCompletedPayload,
  type TurnCompletedPayload,
  type TurnReadyPayload,
  type TurnStartedPayload,
} from './sse_event_generated'

export type OasPayloadParseIssue = {
  eventType: string
  message: string
}

export type OasPayloadParseSuccess<T> = {
  success: true
  data: T
}

export type OasPayloadParseFailure = {
  success: false
  error: { issues: OasPayloadParseIssue[] }
}

export type OasPayloadParseResult<T> =
  | OasPayloadParseSuccess<T>
  | OasPayloadParseFailure

/** Closed union of every OAS event payload the dashboard knows how to parse.
 *  New payload kinds are added here together with their atdgen reader. */
export type TypedOasPayload =
  | { kind: 'agent_started'; payload: AgentStartedPayload }
  | { kind: 'agent_completed'; payload: AgentCompletedPayload }
  | { kind: 'agent_failed'; payload: AgentFailedPayload }
  | { kind: 'tool_called'; payload: ToolCalledPayload }
  | { kind: 'tool_completed'; payload: ToolCompletedPayload }
  | { kind: 'turn_started'; payload: TurnStartedPayload }
  | { kind: 'turn_completed'; payload: TurnCompletedPayload }
  | { kind: 'turn_ready'; payload: TurnReadyPayload }
  | { kind: 'handoff_requested'; payload: HandoffRequestedPayload }
  | { kind: 'handoff_completed'; payload: HandoffCompletedPayload }

/** Discriminant extracted from the closed union.  Keeping the kind literal in
 *  one place (the union above) eliminates the manual array/switch duplication
 *  that previously required touching three sites for every new payload kind. */
export type OasPayloadKind = TypedOasPayload['kind']

type PayloadReader<T> = (raw: unknown, context?: unknown) => T

type ReaderMap = {
  [K in OasPayloadKind]: PayloadReader<Extract<TypedOasPayload, { kind: K }>['payload']>
}

/** Exhaustive map from payload kind to its atdgen reader.  The mapped type
 *  guarantees every union member has a reader and that no stale kind lingers
 *  after the union changes. */
const READERS: ReaderMap = {
  agent_started: readAgentStartedPayload,
  agent_completed: readAgentCompletedPayload,
  agent_failed: readAgentFailedPayload,
  tool_called: readToolCalledPayload,
  tool_completed: readToolCompletedPayload,
  turn_started: readTurnStartedPayload,
  turn_completed: readTurnCompletedPayload,
  turn_ready: readTurnReadyPayload,
  handoff_requested: readHandoffRequestedPayload,
  handoff_completed: readHandoffCompletedPayload,
}

/** Runtime inventory derived from the reader keys.  The type assertion is
 *  safe because ReaderMap's keys are exactly OasPayloadKind. */
export const OAS_PAYLOAD_EVENT_TYPES = Object.keys(READERS) as readonly OasPayloadKind[]

type OasPayloadEventType = (typeof OAS_PAYLOAD_EVENT_TYPES)[number]

function isOasPayloadEventType(value: string): value is OasPayloadEventType {
  return (OAS_PAYLOAD_EVENT_TYPES as readonly string[]).includes(value)
}

function ok<T>(data: T): OasPayloadParseSuccess<T> {
  return { success: true, data }
}

function fail(eventType: string, message: string): OasPayloadParseFailure {
  return { success: false, error: { issues: [{ eventType, message }] } }
}

function tryRead<T>(
  eventType: string,
  reader: PayloadReader<T>,
  raw: unknown,
): OasPayloadParseResult<T> {
  try {
    return ok(reader(raw, raw))
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return fail(eventType, message)
  }
}

function buildPayload<K extends OasPayloadKind>(
  kind: K,
  payload: TypedOasPayload['payload'],
): TypedOasPayload {
  return { kind, payload } as unknown as TypedOasPayload
}

/** Parse an OAS event payload into a typed, discriminated union.
 *  Returns a structured error if the event type is unknown or the payload
 *  fails atdgen validation. */
export function parseOasPayload(
  eventType: string,
  raw: unknown,
): OasPayloadParseResult<TypedOasPayload> {
  const suffix = eventType.startsWith(OAS_EVENT_PREFIX)
    ? eventType.slice(OAS_EVENT_PREFIX.length)
    : eventType
  if (!isOasPayloadEventType(suffix)) {
    return fail(eventType, `No typed payload reader for event type "${eventType}"`)
  }

  switch (suffix) {
    case 'agent_started':
    case 'agent_completed':
    case 'agent_failed':
    case 'tool_called':
    case 'tool_completed':
    case 'turn_started':
    case 'turn_completed':
    case 'turn_ready':
    case 'handoff_requested':
    case 'handoff_completed': {
      const result = tryRead(eventType, READERS[suffix] as PayloadReader<unknown>, raw)
      if (!result.success) return result
      return ok(buildPayload(suffix, result.data as TypedOasPayload['payload']))
    }
  }
  return assertExhaustive(suffix, 'OasPayloadKind')
}

/** Convenience wrapper that returns the typed payload or null.
 *  Use this when the caller intends to drop malformed events silently. */
export function parseOasPayloadOrNull(
  eventType: string,
  raw: unknown,
): TypedOasPayload | null {
  const result = parseOasPayload(eventType, raw)
  return result.success ? result.data : null
}

/** Convenience wrapper that returns the typed payload or throws.
 *  Use this only when a parse failure should be treated as an unrecoverable
 *  invariant violation. */
export function parseOasPayloadStrict(
  eventType: string,
  raw: unknown,
): TypedOasPayload {
  const result = parseOasPayload(eventType, raw)
  if (!result.success) {
    throw new SSEPayloadParseError(result.error.issues)
  }
  return result.data
}

export class SSEPayloadParseError extends Error {
  constructor(public readonly issues: readonly OasPayloadParseIssue[]) {
    super(`SSE payload parse error: ${issues.map(i => i.message).join('; ')}`)
    this.name = 'SSEPayloadParseError'
  }
}
