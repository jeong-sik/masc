// MASC collab web viewer — relay wire codec (RFC-0471 §2.3–2.5).
//
// Ports Collab_envelope, Collab_wire control/close codes, and Collab_frame:
// binary messages are `[4B big-endian peer][sealed payload]`, text messages
// are relay control JSON, and sealed payloads are tagged-object frame JSON.
// Decode is strict like the OCaml side (unknown tag, missing or mistyped
// field, or negative int where only non-negative is valid → null); unknown
// extra fields are ignored so later stacks extend without breaking this one.

export const COLLAB_PROTO_VERSION = 1
export const COLLAB_ENVELOPE_HEADER_LENGTH = 4
export const COLLAB_BROADCAST_PEER = 0
export const COLLAB_MAX_PEER = 0xffffffff

// --- Envelope ---

export function packCollabEnvelope(peer: number, payload: Uint8Array): Uint8Array {
  if (!Number.isInteger(peer) || peer < 0 || peer > COLLAB_MAX_PEER) {
    throw new Error(`collab peer id out of range: ${peer}`)
  }
  const out = new Uint8Array(COLLAB_ENVELOPE_HEADER_LENGTH + payload.length)
  new DataView(out.buffer, out.byteOffset, out.byteLength).setUint32(0, peer)
  out.set(payload, COLLAB_ENVELOPE_HEADER_LENGTH)
  return out
}

export function unpackCollabEnvelope(
  bytes: Uint8Array,
): { peer: number; payload: Uint8Array } | null {
  if (bytes.length < COLLAB_ENVELOPE_HEADER_LENGTH) return null
  const peer = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0)
  return { peer, payload: bytes.slice(COLLAB_ENVELOPE_HEADER_LENGTH) }
}

// --- Relay control (text messages, relay → peer) ---

export type CollabControl =
  | { kind: 'peer-joined'; peer: number }
  | { kind: 'peer-left'; peer: number }
  | { kind: 'room-closed' }

export function decodeCollabControl(text: string): CollabControl | null {
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof json !== 'object' || json === null || Array.isArray(json)) return null
  const record = json as Record<string, unknown>
  const tag = record.t
  if (tag === 'room-closed') return { kind: 'room-closed' }
  if (tag === 'peer-joined' || tag === 'peer-left') {
    const peer = record.peer
    if (typeof peer !== 'number' || !Number.isInteger(peer) || peer < 1 || peer > COLLAB_MAX_PEER) {
      return null
    }
    return tag === 'peer-joined' ? { kind: 'peer-joined', peer } : { kind: 'peer-left', peer }
  }
  return null
}

// --- Close codes (omp mirror; browsers only see the code) ---

export const COLLAB_CLOSE_ROOM_CLOSED = 4001
export const COLLAB_CLOSE_NO_SUCH_ROOM = 4004
export const COLLAB_CLOSE_HOST_CONFLICT = 4009
export const COLLAB_CLOSE_ROOM_FULL = 4029

export function collabCloseText(code: number): string {
  switch (code) {
    case COLLAB_CLOSE_ROOM_CLOSED:
      return 'The host ended this session.'
    case COLLAB_CLOSE_NO_SUCH_ROOM:
      return 'No such room — the link may be stale.'
    case COLLAB_CLOSE_HOST_CONFLICT:
      return 'The host reconnected elsewhere; this session moved.'
    case COLLAB_CLOSE_ROOM_FULL:
      return 'This room is full.'
    default:
      return `The relay closed the connection (${code}).`
  }
}

// --- Frames (sealed JSON) ---

export interface CollabHello {
  kind: 'hello'
  proto: number
  writeToken: string | null
  label: string | null
}

export interface CollabWelcome {
  kind: 'welcome'
  proto: number
  keeper: string
  operation: string
  active: boolean
  guests: number
  entryCount: number
  readOnly: boolean
}

export interface CollabSnapshotChunk {
  kind: 'snapshot-chunk'
  entries: unknown[]
  final: boolean
}

export interface CollabEntry {
  kind: 'entry'
  seq: number
  op: string
  opSeq: number
  ts: number
  event: unknown
}

export interface CollabLiveState {
  kind: 'state'
  active: boolean
  guests: number
}

export interface CollabPrompt {
  kind: 'prompt'
  text: string
}

export interface CollabAbort {
  kind: 'abort'
}

export interface CollabFetchTranscript {
  kind: 'fetch-transcript'
  reqId: number
  maxBytes: number
}

export interface CollabTranscript {
  kind: 'transcript'
  reqId: number
  text: string
  newSize: number
  error: string | null
}

export interface CollabBye {
  kind: 'bye'
  reason: string
}

export interface CollabErrorFrame {
  kind: 'error'
  message: string
}

export type CollabFrame =
  | CollabHello
  | CollabWelcome
  | CollabSnapshotChunk
  | CollabEntry
  | CollabLiveState
  | CollabPrompt
  | CollabAbort
  | CollabFetchTranscript
  | CollabTranscript
  | CollabBye
  | CollabErrorFrame

function isInt(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value)
}

function isNonnegInt(value: unknown): value is number {
  return isInt(value) && value >= 0
}

function optString(record: Record<string, unknown>, name: string): string | null | undefined {
  if (!(name in record)) return null
  const value = record[name]
  if (value === null) return null
  if (typeof value === 'string') return value
  return undefined
}

export function decodeCollabFrame(json: unknown): CollabFrame | null {
  if (typeof json !== 'object' || json === null || Array.isArray(json)) return null
  const record = json as Record<string, unknown>
  const tag = record.t
  switch (tag) {
    case 'hello': {
      const proto = record.proto
      const writeToken = optString(record, 'write_token')
      const label = optString(record, 'label')
      if (!isInt(proto) || writeToken === undefined || label === undefined) return null
      return { kind: 'hello', proto, writeToken, label }
    }
    case 'welcome': {
      const proto = record.proto
      const header = record.header
      const state = record.state
      const entryCount = record.entry_count
      const readOnly = record.read_only
      if (
        !isInt(proto) ||
        typeof header !== 'object' || header === null || Array.isArray(header) ||
        typeof state !== 'object' || state === null || Array.isArray(state) ||
        !isNonnegInt(entryCount) ||
        typeof readOnly !== 'boolean'
      ) {
        return null
      }
      const keeper = (header as Record<string, unknown>).keeper
      const operation = (header as Record<string, unknown>).operation
      const active = (state as Record<string, unknown>).active
      const guests = (state as Record<string, unknown>).guests
      if (
        typeof keeper !== 'string' || typeof operation !== 'string' ||
        typeof active !== 'boolean' || !isNonnegInt(guests)
      ) {
        return null
      }
      return {
        kind: 'welcome', proto, keeper, operation, active, guests,
        entryCount, readOnly,
      }
    }
    case 'snapshot-chunk': {
      const entries = record.entries
      const final = record.final
      if (!Array.isArray(entries) || typeof final !== 'boolean') return null
      return { kind: 'snapshot-chunk', entries, final }
    }
    case 'entry': {
      const seq = record.seq
      const op = record.op
      const opSeq = record.op_seq
      const ts = record.ts
      if (
        !isNonnegInt(seq) || typeof op !== 'string' || !isNonnegInt(opSeq) ||
        typeof ts !== 'number' || !('event' in record)
      ) {
        return null
      }
      return { kind: 'entry', seq, op, opSeq, ts, event: record.event }
    }
    case 'state': {
      const active = record.active
      const guests = record.guests
      if (typeof active !== 'boolean' || !isNonnegInt(guests)) return null
      return { kind: 'state', active, guests }
    }
    case 'prompt': {
      if (typeof record.text !== 'string') return null
      return { kind: 'prompt', text: record.text }
    }
    case 'abort':
      return { kind: 'abort' }
    case 'fetch-transcript': {
      const reqId = record.req_id
      const maxBytes = record.max_bytes
      if (!isNonnegInt(reqId) || !isNonnegInt(maxBytes)) return null
      return { kind: 'fetch-transcript', reqId, maxBytes }
    }
    case 'transcript': {
      const reqId = record.req_id
      const text = record.text
      const newSize = record.new_size
      const error = optString(record, 'error')
      if (!isNonnegInt(reqId) || typeof text !== 'string' || !isNonnegInt(newSize) || error === undefined) {
        return null
      }
      return { kind: 'transcript', reqId, text, newSize, error }
    }
    case 'bye': {
      if (typeof record.reason !== 'string') return null
      return { kind: 'bye', reason: record.reason }
    }
    case 'error': {
      if (typeof record.message !== 'string') return null
      return { kind: 'error', message: record.message }
    }
    default:
      return null
  }
}

export function decodeCollabFrameText(text: string): CollabFrame | null {
  try {
    return decodeCollabFrame(JSON.parse(text))
  } catch {
    return null
  }
}

function framePayload(frame: CollabFrame): Record<string, unknown> {
  switch (frame.kind) {
    case 'hello': {
      const out: Record<string, unknown> = { t: 'hello', proto: frame.proto }
      if (frame.writeToken !== null) out.write_token = frame.writeToken
      if (frame.label !== null) out.label = frame.label
      return out
    }
    case 'welcome':
      return {
        t: 'welcome',
        proto: frame.proto,
        header: { keeper: frame.keeper, operation: frame.operation },
        state: { active: frame.active, guests: frame.guests },
        entry_count: frame.entryCount,
        read_only: frame.readOnly,
      }
    case 'snapshot-chunk':
      return { t: 'snapshot-chunk', entries: frame.entries, final: frame.final }
    case 'entry':
      return {
        t: 'entry', seq: frame.seq, op: frame.op, op_seq: frame.opSeq, ts: frame.ts,
        event: frame.event,
      }
    case 'state':
      return { t: 'state', active: frame.active, guests: frame.guests }
    case 'prompt':
      return { t: 'prompt', text: frame.text }
    case 'abort':
      return { t: 'abort' }
    case 'fetch-transcript':
      return { t: 'fetch-transcript', req_id: frame.reqId, max_bytes: frame.maxBytes }
    case 'transcript': {
      const out: Record<string, unknown> = {
        t: 'transcript', req_id: frame.reqId, text: frame.text, new_size: frame.newSize,
      }
      if (frame.error !== null) out.error = frame.error
      return out
    }
    case 'bye':
      return { t: 'bye', reason: frame.reason }
    case 'error':
      return { t: 'error', message: frame.message }
  }
}

export function encodeCollabFrame(frame: CollabFrame): string {
  return JSON.stringify(framePayload(frame))
}
