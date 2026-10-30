import { isRecord } from '../components/common/normalize'

export type UnreadReason = 'context_overflow' | 'input_capacity' | 'request_body_refused'
export type UnreadSource =
  | { kind: 'atom'; trace_id: string; history_start_boundary_line: number;
      atom: number; message_in_atom: number; message_sha256: string }
  | { kind: 'official_turn'; turn_ref: string; boundary_line: number;
      message_in_turn: number; message_sha256: string }
export interface UnreadMessage { source: UnreadSource; reasons: UnreadReason[] }
export type UnreadReading = { kind: 'available'; messages: UnreadMessage[] }
  | { kind: 'unavailable' }
export interface UnreadEvidence { snapshot: UnreadReading; memory: UnreadReading }

const reasons: UnreadReason[] = ['context_overflow', 'input_capacity', 'request_body_refused']
function exact(value: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key))
}
function integer(value: unknown, minimum: number): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= minimum
}
function message(raw: unknown): UnreadMessage | null {
  if (!isRecord(raw) || !exact(raw, ['source', 'reasons']) || !isRecord(raw.source)) return null
  if (!Array.isArray(raw.reasons) || raw.reasons.length === 0) return null
  const parsed: UnreadReason[] = []
  let previous = -1
  for (const reason of raw.reasons) {
    const index = reasons.findIndex(candidate => candidate === reason)
    if (index <= previous) return null
    previous = index
    const named = reasons[index]
    if (named === undefined) return null
    parsed.push(named)
  }
  const source = raw.source
  if (typeof source.message_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(source.message_sha256)) return null
  if (source.kind === 'atom') {
    if (!exact(source, ['kind', 'trace_id', 'history_start_boundary_line', 'atom', 'message_in_atom', 'message_sha256'])
      || typeof source.trace_id !== 'string' || source.trace_id.trim() === ''
      || !integer(source.history_start_boundary_line, 1) || !integer(source.atom, 0)
      || !integer(source.message_in_atom, 0)) return null
    return { source: { kind: 'atom', trace_id: source.trace_id,
      history_start_boundary_line: source.history_start_boundary_line, atom: source.atom,
      message_in_atom: source.message_in_atom, message_sha256: source.message_sha256 }, reasons: parsed }
  }
  if (source.kind === 'official_turn') {
    if (!exact(source, ['kind', 'turn_ref', 'boundary_line', 'message_in_turn', 'message_sha256'])
      || typeof source.turn_ref !== 'string' || !integer(source.boundary_line, 1)
      || !integer(source.message_in_turn, 0)) return null
    const split = source.turn_ref.lastIndexOf('#')
    const turn = source.turn_ref.slice(split + 1)
    if (split < 1 || source.turn_ref.slice(0, split).trim() === ''
      || !/^[1-9][0-9]*$/.test(turn) || !integer(Number(turn), 1)) return null
    return { source: { kind: 'official_turn', turn_ref: source.turn_ref,
      boundary_line: source.boundary_line, message_in_turn: source.message_in_turn,
      message_sha256: source.message_sha256 }, reasons: parsed }
  }
  return null
}
function reading(raw: unknown): UnreadReading | null {
  if (!isRecord(raw)) return null
  if (raw.kind === 'unavailable') return exact(raw, ['kind']) ? { kind: 'unavailable' } : null
  if (raw.kind !== 'available' || !exact(raw, ['kind', 'messages']) || !Array.isArray(raw.messages)) return null
  const messages: UnreadMessage[] = []
  const seen = new Set<string>()
  for (const value of raw.messages) {
    const parsed = message(value)
    if (parsed === null) return null
    const source = parsed.source
    const key = JSON.stringify(source.kind === 'atom'
      ? ['atom', source.trace_id, source.history_start_boundary_line, source.atom, source.message_in_atom]
      : ['official_turn', source.turn_ref, source.boundary_line, source.message_in_turn])
    if (seen.has(key)) return null
    seen.add(key)
    messages.push(parsed)
  }
  return { kind: 'available', messages }
}
export function decodeUnreadEvidence(raw: unknown): UnreadEvidence | null {
  if (!isRecord(raw) || !exact(raw, ['snapshot', 'memory'])) return null
  const snapshot = reading(raw.snapshot), memory = reading(raw.memory)
  if (snapshot === null || memory === null) return null
  if (snapshot.kind === 'available' && snapshot.messages.some(entry => entry.source.kind !== 'atom')) return null
  return { snapshot, memory }
}
