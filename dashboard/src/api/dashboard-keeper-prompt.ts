// MASC Dashboard — retained redacted execution records and keeper prompt state.
//
// Routes: GET /api/v1/keepers/:name/last-prompt    assembled context, as text
//         GET /api/v1/keepers/:name/raw-traces     which turns exist
//         GET /api/v1/keepers/:name/raw-trace      one turn's records
//         GET /api/v1/keepers/:name/operator-note  pending or consumed
//
// Every decoder here rejects rather than repairs. A payload this build cannot
// read is a contract error the panel shows, not a shorter list it renders as
// if it were complete — the whole point of these surfaces is that an operator
// can trust what they are looking at.

import { get, post, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import { isRecord, asNumber, asString } from '../components/common/normalize'
import { decodeTurnPromptBlockId, type TurnPromptBlockId } from './dashboard-turn-records'

export type PromptCaptureBlock = {
  readonly id: TurnPromptBlockId
  readonly bytes: number
  readonly text: string
}

export type PromptCapture = {
  readonly keeper: string
  readonly capturedAt: number
  readonly traceId: string
  readonly absoluteTurn: number
  readonly blocks: readonly PromptCaptureBlock[]
  readonly assembled: string | null
  readonly assembledBytes: number
}

function decodeCaptureBlock(raw: unknown): PromptCaptureBlock | null {
  if (!isRecord(raw)) return null
  const id = decodeTurnPromptBlockId(raw.id)
  const bytes = asNumber(raw.bytes)
  const text = typeof raw.text === 'string' ? raw.text : null
  if (id === null || bytes == null || !Number.isSafeInteger(bytes) || bytes < 0 || text === null) {
    return null
  }
  return { id, bytes, text }
}

function decodeCapture(raw: unknown): PromptCapture | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const capturedAt = asNumber(raw.captured_at)
  const traceId = asString(raw.trace_id)
  const absoluteTurn = asNumber(raw.absolute_turn)
  const assembledBytes = asNumber(raw.assembled_bytes)
  if (keeper == null || capturedAt == null || traceId == null || absoluteTurn == null) return null
  if (assembledBytes == null || !Number.isSafeInteger(assembledBytes)) return null
  if (!Array.isArray(raw.blocks)) return null
  const blocks: PromptCaptureBlock[] = []
  for (const item of raw.blocks) {
    const block = decodeCaptureBlock(item)
    // A block this build cannot read means the capture came from a wider
    // build. Dropping it would show a shorter prompt than the keeper got.
    if (block === null) return null
    blocks.push(block)
  }
  const assembled = raw.assembled === null ? null : typeof raw.assembled === 'string' ? raw.assembled : null
  if (raw.assembled !== null && assembled === null) return null
  return { keeper, capturedAt, traceId, absoluteTurn, blocks, assembled, assembledBytes }
}

export async function fetchKeeperLastPrompt(
  name: string,
  opts?: AbortableRequestOptions,
): Promise<PromptCapture> {
  await ensureDevToken()
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/last-prompt`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeCapture(raw)
    if (!decoded) throw new Error('유효하지 않은 prompt capture payload')
    return decoded
  })
}

// The listing reads a bounded prefix of each turn file, so a turn larger than
// that budget arrives without a record count. That is a distinct state, not a
// zero and not a missing field: a union here makes the panel decide what it
// shows instead of letting a default stand in for a count nobody took.
export type RawTraceCensus =
  | { readonly state: 'whole_file'; readonly records: number }
  | { readonly state: 'prefix_only'; readonly budgetBytes: number }

export type RawTraceTurn = {
  readonly file: string
  readonly traceId: string | null
  readonly bytes: number
  readonly census: RawTraceCensus
  readonly modifiedAt: number
}

function decodeCensus(raw: unknown): RawTraceCensus | null {
  if (!isRecord(raw)) return null
  const state = asString(raw.state)
  if (state === 'whole_file') {
    const records = asNumber(raw.records)
    if (records == null || !Number.isSafeInteger(records)) return null
    return { state, records }
  }
  if (state === 'prefix_only') {
    const budgetBytes = asNumber(raw.budget_bytes)
    if (budgetBytes == null || !Number.isSafeInteger(budgetBytes)) return null
    return { state, budgetBytes }
  }
  return null
}

function decodeTurnSummary(raw: unknown): RawTraceTurn | null {
  if (!isRecord(raw)) return null
  const file = asString(raw.file)
  if (!Object.hasOwn(raw, 'trace_id')) return null
  let traceId: string | null
  if (raw.trace_id === null) traceId = null
  else {
    const decoded = asString(raw.trace_id)
    if (decoded == null) return null
    traceId = decoded
  }
  const bytes = asNumber(raw.bytes)
  const census = decodeCensus(raw.census)
  const modifiedAt = asNumber(raw.modified_at)
  if (file == null || bytes == null || census == null || modifiedAt == null) return null
  if (!Number.isSafeInteger(bytes)) return null
  return { file, traceId, bytes, census, modifiedAt }
}

export async function fetchKeeperRawTraces(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<readonly RawTraceTurn[]> {
  await ensureDevToken()
  const params = limit == null ? '' : `?limit=${encodeURIComponent(String(limit))}`
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/raw-traces${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    if (!isRecord(raw) || !Array.isArray(raw.turns)) {
      throw new Error('유효하지 않은 raw trace 목록 payload')
    }
    const turns: RawTraceTurn[] = []
    for (const item of raw.turns) {
      const turn = decodeTurnSummary(item)
      if (turn === null) throw new Error('유효하지 않은 raw trace 목록 payload')
      turns.push(turn)
    }
    return turns
  })
}

// A line the server could not parse keeps its position and says so. Collapsing
// it to an omission would make a damaged trace read as a shorter one.
export type RawTraceRecord =
  | { readonly ok: true; readonly raw: string; readonly record: Record<string, unknown> }
  | { readonly ok: false; readonly raw: string; readonly error: string }

export type RawTracePage = {
  readonly file: string
  readonly totalRecords: number
  readonly offset: number
  readonly records: readonly RawTraceRecord[]
}

function decodeRawRecord(raw: unknown): RawTraceRecord | null {
  if (!isRecord(raw)) return null
  const literal = asString(raw.raw)
  if (literal == null) return null
  if (raw.ok === true) {
    return isRecord(raw.record) ? { ok: true, raw: literal, record: raw.record } : null
  }
  if (raw.ok === false) {
    const error = asString(raw.error)
    return error == null ? null : { ok: false, raw: literal, error }
  }
  return null
}

export async function fetchKeeperRawTrace(
  name: string,
  file: string,
  opts?: AbortableRequestOptions & { offset?: number; limit?: number },
): Promise<RawTracePage> {
  await ensureDevToken()
  const query = new URLSearchParams({ file })
  if (opts?.offset != null) query.set('offset', String(opts.offset))
  if (opts?.limit != null) query.set('limit', String(opts.limit))
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/raw-trace?${query.toString()}`,
    { signal: opts?.signal },
  ).then((raw) => {
    if (!isRecord(raw)) throw new Error('유효하지 않은 raw trace payload')
    const fileName = asString(raw.file)
    const totalRecords = asNumber(raw.total_records)
    const offset = asNumber(raw.offset)
    if (fileName == null || totalRecords == null || offset == null) {
      throw new Error('유효하지 않은 raw trace payload')
    }
    if (!Array.isArray(raw.records)) throw new Error('유효하지 않은 raw trace payload')
    const records: RawTraceRecord[] = []
    for (const item of raw.records) {
      const record = decodeRawRecord(item)
      if (record === null) throw new Error('유효하지 않은 raw trace payload')
      records.push(record)
    }
    return { file: fileName, totalRecords, offset, records }
  })
}

export type OperatorNote = {
  readonly keeper: string
  readonly pending: boolean
  readonly text: string
  readonly createdBy: string
  readonly createdAt: number
  readonly consumedTurn: number | null
}

// Replaces this keeper's pending note. The server rejects oversized text
// rather than truncating it, and the rejection reaches the caller as a thrown
// error carrying the server's own byte counts — a silently shortened
// instruction is a different instruction.
export async function putKeeperOperatorNote(
  name: string,
  text: string,
): Promise<OperatorNote> {
  await ensureDevToken()
  const raw = await post<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/operator-note`,
    { text },
  )
  if (!isRecord(raw) || raw.ok !== true || !isRecord(raw.note)) {
    const message = isRecord(raw) && typeof raw.error === 'string' ? raw.error : '운영자 노트 저장 실패'
    throw new Error(message)
  }
  return decodeNoteResponse(raw)
}

function decodeNoteResponse(raw: Record<string, unknown>): OperatorNote {
  if (!isRecord(raw.note)) throw new Error('유효하지 않은 operator note payload')
  const keeper = asString(raw.keeper)
  const pending = raw.pending === true ? true : raw.pending === false ? false : null
  const text = asString(raw.note.text)
  const createdBy = asString(raw.note.created_by)
  const createdAt = asNumber(raw.note.created_at)
  if (keeper == null || pending === null || text == null || createdBy == null || createdAt == null) {
    throw new Error('유효하지 않은 operator note payload')
  }
  const consumedTurnRaw = raw.note.consumed_turn
  let consumedTurn: number | null
  if (consumedTurnRaw === null || consumedTurnRaw === undefined) {
    consumedTurn = null
  } else {
    const parsed = asNumber(consumedTurnRaw)
    if (parsed == null || !Number.isSafeInteger(parsed)) {
      throw new Error('유효하지 않은 operator note payload')
    }
    consumedTurn = parsed
  }
  return { keeper, pending, text, createdBy, createdAt, consumedTurn }
}

export async function fetchKeeperOperatorNote(
  name: string,
  opts?: AbortableRequestOptions,
): Promise<OperatorNote> {
  await ensureDevToken()
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/operator-note`,
    { signal: opts?.signal },
  ).then((raw) => {
    if (!isRecord(raw)) throw new Error('유효하지 않은 operator note payload')
    return decodeNoteResponse(raw)
  })
}
