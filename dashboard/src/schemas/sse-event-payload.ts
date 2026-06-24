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

import {
  readAgentCompletedPayload,
  readAgentFailedPayload,
  readAgentStartedPayload,
  readContentReplacementKeptPayload,
  readContentReplacementReplacedPayload,
  readContextCompactStartedPayload,
  readContextCompactedPayload,
  readContextOverflowImminentPayload,
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
  type AgentStartedPayload,
  type ContentReplacementKeptPayload,
  type ContentReplacementReplacedPayload,
  type ContextCompactStartedPayload,
  type ContextCompactedPayload,
  type ContextOverflowImminentPayload,
  type HandoffCompletedPayload,
  type HandoffRequestedPayload,
  type SlotSchedulerObservedPayload,
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
  | { kind: 'agent_failed'; payload: AgentFailedPayload & { error?: string } }
  | { kind: 'tool_called'; payload: ToolCalledPayload }
  | { kind: 'tool_completed'; payload: ToolCompletedPayload }
  | { kind: 'turn_started'; payload: TurnStartedPayload }
  | { kind: 'turn_completed'; payload: TurnCompletedPayload }
  | { kind: 'turn_ready'; payload: TurnReadyPayload }
  | { kind: 'handoff_requested'; payload: HandoffRequestedPayload }
  | { kind: 'handoff_completed'; payload: HandoffCompletedPayload }
  | { kind: 'context_compacted'; payload: ContextCompactedPayload & { runtime?: string } }
  | { kind: 'context_overflow_imminent'; payload: ContextOverflowImminentPayload }
  | { kind: 'context_compact_started'; payload: ContextCompactStartedPayload }
  | { kind: 'content_replacement_replaced'; payload: ContentReplacementReplacedPayload }
  | { kind: 'content_replacement_kept'; payload: ContentReplacementKeptPayload }
  | { kind: 'slot_scheduler_observed'; payload: SlotSchedulerObservedPayload }

const OAS_PAYLOAD_EVENT_TYPES = [
  'agent_started',
  'agent_completed',
  'agent_failed',
  'tool_called',
  'tool_completed',
  'turn_started',
  'turn_completed',
  'turn_ready',
  'handoff_requested',
  'handoff_completed',
  'context_compacted',
  'context_overflow_imminent',
  'context_compact_started',
  'content_replacement_replaced',
  'content_replacement_kept',
  'slot_scheduler_observed',
] as const

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

type PayloadReader<T> = (raw: unknown, context?: unknown) => T

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

function readOptionalString(
  raw: Record<string, unknown>,
  key: string,
): string | undefined {
  const value = raw[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'string') return undefined
  return value
}

/** Parse an OAS event payload into a typed, discriminated union.
 *  Returns a structured error if the event type is unknown or the payload
 *  fails atdgen validation. */
export function parseOasPayload(
  eventType: string,
  raw: unknown,
): OasPayloadParseResult<TypedOasPayload> {
  const suffix = eventType.startsWith('oas:') ? eventType.slice(4) : eventType
  if (!isOasPayloadEventType(suffix)) {
    return fail(eventType, `No typed payload reader for event type "${eventType}"`)
  }

  const rawRecord =
    typeof raw === 'object' && raw !== null
      ? (raw as Record<string, unknown>)
      : {}

  switch (suffix) {
    case 'agent_started': {
      const result = tryRead(eventType, readAgentStartedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'agent_started', payload: result.data })
    }
    case 'agent_completed': {
      const result = tryRead(eventType, readAgentCompletedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'agent_completed', payload: result.data })
    }
    case 'agent_failed': {
      const result = tryRead(eventType, readAgentFailedPayload, raw)
      if (!result.success) return result
      const error = readOptionalString(rawRecord, 'error')
      return ok({ kind: 'agent_failed', payload: { ...result.data, error } })
    }
    case 'tool_called': {
      const result = tryRead(eventType, readToolCalledPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'tool_called', payload: result.data })
    }
    case 'tool_completed': {
      const result = tryRead(eventType, readToolCompletedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'tool_completed', payload: result.data })
    }
    case 'turn_started': {
      const result = tryRead(eventType, readTurnStartedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'turn_started', payload: result.data })
    }
    case 'turn_completed': {
      const result = tryRead(eventType, readTurnCompletedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'turn_completed', payload: result.data })
    }
    case 'turn_ready': {
      const result = tryRead(eventType, readTurnReadyPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'turn_ready', payload: result.data })
    }
    case 'handoff_requested': {
      const result = tryRead(eventType, readHandoffRequestedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'handoff_requested', payload: result.data })
    }
    case 'handoff_completed': {
      const result = tryRead(eventType, readHandoffCompletedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'handoff_completed', payload: result.data })
    }
    case 'context_compacted': {
      const result = tryRead(eventType, readContextCompactedPayload, raw)
      if (!result.success) return result
      const runtime = readOptionalString(rawRecord, 'runtime')
      return ok({ kind: 'context_compacted', payload: { ...result.data, runtime } })
    }
    case 'context_overflow_imminent': {
      const result = tryRead(eventType, readContextOverflowImminentPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'context_overflow_imminent', payload: result.data })
    }
    case 'context_compact_started': {
      const result = tryRead(eventType, readContextCompactStartedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'context_compact_started', payload: result.data })
    }
    case 'content_replacement_replaced': {
      const result = tryRead(eventType, readContentReplacementReplacedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'content_replacement_replaced', payload: result.data })
    }
    case 'content_replacement_kept': {
      const result = tryRead(eventType, readContentReplacementKeptPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'content_replacement_kept', payload: result.data })
    }
    case 'slot_scheduler_observed': {
      const result = tryRead(eventType, readSlotSchedulerObservedPayload, raw)
      if (!result.success) return result
      return ok({ kind: 'slot_scheduler_observed', payload: result.data })
    }
  }
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
