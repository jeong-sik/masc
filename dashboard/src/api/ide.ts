import { get, post, fetchWithTimeout, authHeaders, type GetOptions } from './core'
import {
  type IdeAnnotation,
  type IdeAnnotationReference,
  type IdeCodeRegion,
  type AnnotationKind,
  parseIdeAnnotation,
} from './schemas/ide-annotations'
import { isRecord } from '../lib/type-guards'

export type {
  IdeAnnotation,
  IdeAnnotationReference,
  IdeCodeRegion,
  AnnotationKind,
} from './schemas/ide-annotations'

export interface IdeApiOptions extends GetOptions {
  readonly keeper?: string
  readonly scope?: IdeScope | null
  readonly repoId?: string | null
  readonly canonicalUrl?: string | null
}

export type IdeScope =
  | { readonly kind: 'repo_id'; readonly repoId: string }
  | { readonly kind: 'canonical_url'; readonly canonicalUrl: string }
  /**
   * Read-only scope over the repo-unattributed observation lane. Keeper
   * turn/coordination events carry no file, so the server stores them
   * outside any repo partition; this scope is the only address for that
   * data. Mutations sent with it are refused server-side
   * (keeper_lane_read_only).
   */
  | { readonly kind: 'keeper_lane'; readonly keeperId: string }

export type IdeScopeOptions = Pick<IdeApiOptions, 'scope' | 'repoId' | 'canonicalUrl'>

export type IdeEventKind = 'tool' | 'turn'

export interface IdeEventsOptions extends IdeApiOptions {
  readonly kind?: IdeEventKind | 'all'
  readonly keeperId?: string
  readonly limit?: number
  readonly offset?: number
}

export type IdeCursorFocusMode = 'reading' | 'editing' | 'reviewing' | 'planning'

export interface IdeCursorEntry {
  readonly keeper_id: string
  readonly file_path: string
  readonly line: number
  readonly column: number
  readonly selection_end?: { readonly line: number; readonly column: number }
  readonly focus_mode: IdeCursorFocusMode
  readonly last_update: number
  readonly tool_name?: string
  readonly turn?: number
  readonly turn_id?: string
}

export interface IdeCursorSnapshot {
  readonly runtime_id: string
  readonly branch?: string
  readonly connected: boolean
  readonly cursors: ReadonlyArray<IdeCursorEntry>
}

export interface IdeCursorOptions extends IdeApiOptions {
  readonly keeperId?: string
  readonly filePath?: string
  readonly limit?: number
  readonly offset?: number
}

interface IdeBridgeEventBase {
  readonly type: IdeEventKind
  readonly keeper_id: string
  readonly turn_id: string
  readonly timestamp_ms: number
}

export interface IdeToolEvent extends IdeBridgeEventBase {
  readonly type: 'tool'
  readonly tool_name: string
  readonly outcome: string
  readonly typed_outcome: string
  readonly latency_ms: number
  readonly summary: string
  readonly file_path: string | null
}

export interface IdeTurnEvent extends IdeBridgeEventBase {
  readonly type: 'turn'
  readonly phase: string
  readonly model_used: string | null
  readonly tools_used: ReadonlyArray<string>
  readonly stop_reason: string | null
  readonly duration_ms: number | null
}

export type IdeBridgeEvent = IdeToolEvent | IdeTurnEvent

export interface IdeAnnotationFilter {
  readonly file_path?: string
  readonly keeper_id?: string
  readonly goal_id?: string
  readonly task_id?: string
}

export interface CreateAnnotationInput {
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly kind: AnnotationKind
  readonly content: string
  readonly goal_id?: string
  readonly task_id?: string
  readonly references?: ReadonlyArray<IdeAnnotationReference>
}

function appendFilterParams(
  params: URLSearchParams,
  filter: IdeAnnotationFilter,
): void {
  if (filter.file_path) params.set('file_path', filter.file_path)
  if (filter.keeper_id) params.set('keeper_id', filter.keeper_id)
  if (filter.goal_id) params.set('goal_id', filter.goal_id)
  if (filter.task_id) params.set('task_id', filter.task_id)
}

function trimmedNonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

export function ideScopeFromRepoId(repoId: string | null | undefined): IdeScope | null {
  const trimmed = trimmedNonEmpty(repoId)
  return trimmed ? { kind: 'repo_id', repoId: trimmed } : null
}

export function ideScopeFromCanonicalUrl(canonicalUrl: string | null | undefined): IdeScope | null {
  const trimmed = trimmedNonEmpty(canonicalUrl)
  return trimmed ? { kind: 'canonical_url', canonicalUrl: trimmed } : null
}

export function ideScopeFromKeeperLane(keeperId: string | null | undefined): IdeScope | null {
  const trimmed = trimmedNonEmpty(keeperId)
  return trimmed ? { kind: 'keeper_lane', keeperId: trimmed } : null
}

function resolveIdeScope(opts: IdeScopeOptions): IdeScope | null {
  const candidates: IdeScope[] = []
  if (opts.scope) candidates.push(opts.scope)
  const repoScope = ideScopeFromRepoId(opts.repoId)
  if (repoScope) candidates.push(repoScope)
  const canonicalScope = ideScopeFromCanonicalUrl(opts.canonicalUrl)
  if (canonicalScope) candidates.push(canonicalScope)
  if (candidates.length > 1) {
    throw new Error(
      'IDE scope must resolve to exactly one of repo_id, canonical_url, or keeper_lane',
    )
  }
  return candidates[0] ?? null
}

export function appendIdeScopeParams(params: URLSearchParams, opts: IdeScopeOptions): void {
  const scope = resolveIdeScope(opts)
  if (!scope) return
  switch (scope.kind) {
    case 'repo_id':
      params.set('repo_id', scope.repoId)
      break
    case 'canonical_url':
      params.set('canonical_url', scope.canonicalUrl)
      break
    case 'keeper_lane':
      params.set('keeper_lane', scope.keeperId)
      break
  }
}

function appendWorkspaceParams(
  params: URLSearchParams,
  opts: IdeApiOptions,
): void {
  if (opts.keeper) params.set('keeper', opts.keeper)
  appendIdeScopeParams(params, opts)
}

function ideEnvelopeData(raw: unknown, operation: string): unknown {
  if (!isRecord(raw)) throw new Error(`${operation} returned a malformed response envelope`)
  if (raw.ok !== true) {
    const message = typeof raw.error === 'string' && raw.error.trim() !== ''
      ? raw.error.trim()
      : `${operation} failed`
    throw new Error(message)
  }
  return raw.data
}

function ideEnvelopeRecord(raw: unknown, operation: string): Record<string, unknown> {
  const data = ideEnvelopeData(raw, operation)
  if (!isRecord(data)) throw new Error(`${operation} returned malformed data`)
  return data
}

function parseStrictRows<T>(
  operation: string,
  data: unknown,
  parse: (value: unknown) => T | null,
): ReadonlyArray<T> {
  if (!Array.isArray(data)) throw new Error(`${operation} returned malformed data`)
  const parsed = data.map(parse)
  const invalidIndex = parsed.findIndex(item => item === null)
  if (invalidIndex >= 0) {
    throw new Error(`${operation} returned malformed row at index ${invalidIndex}`)
  }
  return parsed as ReadonlyArray<T>
}

function parseStrictRow<T>(
  operation: string,
  data: unknown,
  parse: (value: unknown) => T | null,
): T {
  const parsed = parse(data)
  if (parsed === null) throw new Error(`${operation} returned malformed row`)
  return parsed
}

function nullableStringField(record: Record<string, unknown>, key: string): string | null | undefined {
  const value = record[key]
  if (value === undefined || value === null) return null
  return typeof value === 'string' ? value : undefined
}

function integerField(record: Record<string, unknown>, key: string): number | null {
  const value = numberField(record, key)
  return value !== null && Number.isInteger(value) ? value : null
}

function positiveIntegerField(record: Record<string, unknown>, key: string): number | null {
  const value = integerField(record, key)
  return value !== null && value > 0 ? value : null
}

function parseStrictIdeAnnotation(raw: unknown): IdeAnnotation | null {
  return parseIdeAnnotation(raw)
}

function parseStrictIdeCodeRegion(raw: unknown): IdeCodeRegion | null {
  if (!isRecord(raw)) return null
  const source = isRecord(raw.source) ? raw.source : null
  if (source === null) return null
  const filePath = stringField(raw, 'file_path')
  const lineStart = positiveIntegerField(raw, 'line_start')
  const lineEnd = positiveIntegerField(raw, 'line_end')
  const keeperId = stringField(raw, 'keeper_id')
  const sourceType = stringField(source, 'type')
  const sourceToolName = nullableStringField(source, 'tool_name')
  const sourceTurn = sourceType === 'tool_call' ? integerField(source, 'turn') : null
  const sourceNote = sourceType === 'manual' ? nullableStringField(source, 'note') : null
  const timestampMs = numberField(raw, 'timestamp_ms')
  if (
    !filePath
    || lineStart === null
    || lineEnd === null
    || lineEnd < lineStart
    || !keeperId
    || (sourceType !== 'tool_call' && sourceType !== 'manual')
    || sourceToolName === undefined
    || sourceNote === undefined
    || (sourceType === 'tool_call' && sourceTurn === null)
    || timestampMs === null
  ) {
    return null
  }
  return {
    file_path: filePath,
    line_start: lineStart,
    line_end: lineEnd,
    keeper_id: keeperId,
    source_type: sourceType,
    source_tool_name: sourceToolName,
    source_turn: sourceTurn,
    source_note: sourceNote,
    timestamp_ms: timestampMs,
  }
}

export async function fetchIdeAnnotations(
  filter: IdeAnnotationFilter = {},
  opts: IdeApiOptions = {},
): Promise<ReadonlyArray<IdeAnnotation>> {
  const params = new URLSearchParams()
  appendFilterParams(params, filter)
  appendWorkspaceParams(params, opts)
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const raw = await get<unknown>(`/api/v1/ide/annotations${query}`, opts)
  return parseStrictRows('fetchIdeAnnotations', ideEnvelopeData(raw, 'fetchIdeAnnotations'), parseStrictIdeAnnotation)
}

export async function createIdeAnnotation(
  input: CreateAnnotationInput,
  opts: IdeApiOptions = {},
): Promise<IdeAnnotation | null> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const raw = await post<unknown>(`/api/v1/ide/annotations${query}`, input)
  return parseStrictRow('createIdeAnnotation', ideEnvelopeData(raw, 'createIdeAnnotation'), parseStrictIdeAnnotation)
}

// Typed outcome of a DELETE (task-1736 B3 route, token-bound):
// - 'rejected'     403 with the server's annotation_delete_rejected code —
//                  the stored annotation is not owned by the token identity,
//                  or it no longer exists (the server flattens the two).
// - 'forbidden'    403 from the auth layer — the token's tier lacks the
//                  write permission; ownership was never evaluated.
// - 'unauthorized' 401 — missing/expired bearer token.
// - 'error'        transport failure or any other server error.
export type IdeAnnotationDeleteOutcome =
  | 'deleted'
  | 'rejected'
  | 'forbidden'
  | 'unauthorized'
  | 'error'

// Wire constant mirrored from server_ide_http.ml annotation_delete_rejected_code.
const ANNOTATION_DELETE_REJECTED_CODE = 'annotation_delete_rejected'

async function responseErrorCode(res: Response): Promise<string | null> {
  try {
    const body: unknown = await res.json()
    if (isRecord(body) && typeof body.code === 'string') return body.code
    return null
  } catch {
    return null
  }
}

export async function deleteIdeAnnotation(
  id: string,
  opts: IdeApiOptions = {},
): Promise<IdeAnnotationDeleteOutcome> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const path = `/api/v1/ide/annotations/${encodeURIComponent(id)}${query}`
  try {
    const res = await fetchWithTimeout(
      path,
      { method: 'DELETE', headers: authHeaders() },
      15_000,
    )
    if (res.ok) return 'deleted'
    if (res.status === 401) return 'unauthorized'
    if (res.status === 403) {
      const code = await responseErrorCode(res)
      return code === ANNOTATION_DELETE_REJECTED_CODE ? 'rejected' : 'forbidden'
    }
    return 'error'
  } catch {
    return 'error'
  }
}

export async function fetchIdeRegions(
  filePath: string,
  opts: IdeApiOptions = {},
): Promise<ReadonlyArray<IdeCodeRegion>> {
  const params = new URLSearchParams()
  params.set('file_path', filePath)
  appendWorkspaceParams(params, opts)
  const raw = await get<unknown>(`/api/v1/ide/regions?${params.toString()}`, opts)
  return parseStrictRows('fetchIdeRegions', ideEnvelopeData(raw, 'fetchIdeRegions'), parseStrictIdeCodeRegion)
}

export async function fetchIdePresence(
  opts: IdeApiOptions = {},
): Promise<unknown> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  const raw = await get<unknown>(`/api/v1/ide/presence?${params.toString()}`, opts)
  if (!isRecord(raw) || raw.ok !== true) return null
  return raw.data
}

export async function fetchIdeCursors(
  opts: IdeCursorOptions = {},
): Promise<IdeCursorSnapshot | null> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  if (opts.keeperId) params.set('keeper_id', opts.keeperId)
  if (opts.filePath) params.set('file_path', opts.filePath)
  if (opts.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts.offset !== undefined) params.set('offset', String(opts.offset))
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const raw = await get<unknown>(`/api/v1/ide/cursors${query}`, opts)
  const data = ideEnvelopeRecord(raw, 'fetchIdeCursors')
  const snapshot = parseIdeCursorSnapshot(data)
  if (snapshot === null) throw new Error('fetchIdeCursors returned malformed data')
  const cursorRows = data.cursors
  if (!Array.isArray(cursorRows)) throw new Error('fetchIdeCursors returned malformed cursors')
  if (snapshot.cursors.length !== cursorRows.length) {
    throw new Error('fetchIdeCursors returned malformed cursor rows')
  }
  return snapshot
}

export async function fetchIdeEvents(
  opts: IdeEventsOptions = {},
): Promise<ReadonlyArray<IdeBridgeEvent>> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  if (opts.kind && opts.kind !== 'all') params.set('kind', opts.kind)
  if (opts.keeperId) params.set('keeper_id', opts.keeperId)
  if (opts.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts.offset !== undefined) params.set('offset', String(opts.offset))
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const raw = await get<unknown>(`/api/v1/ide/events${query}`, opts)
  const data = ideEnvelopeRecord(raw, 'fetchIdeEvents')
  const events = data.events
  if (!Array.isArray(events)) throw new Error('fetchIdeEvents returned malformed events')
  const parsed = events.map(parseIdeBridgeEvent)
  const invalidIndex = parsed.findIndex(event => event === null)
  if (invalidIndex >= 0) {
    throw new Error(`fetchIdeEvents returned malformed event at index ${invalidIndex}`)
  }
  return parsed.filter(isIdeBridgeEvent)
}

function parseIdeBridgeEvent(raw: unknown): IdeBridgeEvent | null {
  if (!isRecord(raw)) return null
  const type = stringField(raw, 'type')
  const keeperId = stringField(raw, 'keeper_id')
  const turnId = stringField(raw, 'turn_id')
  const timestampMs = numberField(raw, 'timestamp_ms')
  if (!isIdeEventKind(type) || !keeperId || !turnId || timestampMs === null) return null

  if (type === 'tool') {
    const toolName = stringField(raw, 'tool_name')
    const outcome = stringField(raw, 'outcome')
    const typedOutcome = stringField(raw, 'typed_outcome')
    const latencyMs = numberField(raw, 'latency_ms')
    const summary = stringField(raw, 'summary')
    if (!toolName || !outcome || !typedOutcome || latencyMs === null || !summary) return null
    return {
      type,
      keeper_id: keeperId,
      turn_id: turnId,
      timestamp_ms: timestampMs,
      tool_name: toolName,
      outcome,
      typed_outcome: typedOutcome,
      latency_ms: latencyMs,
      summary,
      file_path: stringField(raw, 'file_path'),
    }
  }

  const phase = stringField(raw, 'phase')
  if (!phase) return null
  return {
    type,
    keeper_id: keeperId,
    turn_id: turnId,
    timestamp_ms: timestampMs,
    phase,
    model_used: stringField(raw, 'model_used'),
    tools_used: stringArrayField(raw, 'tools_used'),
    stop_reason: stringField(raw, 'stop_reason'),
    duration_ms: numberField(raw, 'duration_ms'),
  }
}

function isIdeBridgeEvent(value: IdeBridgeEvent | null): value is IdeBridgeEvent {
  return value !== null
}

function isIdeEventKind(value: string | null): value is IdeEventKind {
  return value === 'tool' || value === 'turn'
}

function stringField(record: Record<string, unknown>, key: string): string | null {
  const value = record[key]
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function numberField(record: Record<string, unknown>, key: string): number | null {
  const value = record[key]
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function stringArrayField(record: Record<string, unknown>, key: string): ReadonlyArray<string> {
  const value = record[key]
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

function parseIdeCursorSnapshot(raw: unknown): IdeCursorSnapshot | null {
  if (!isRecord(raw)) return null
  const runtimeId = stringField(raw, 'runtime_id')
  if (!runtimeId) return null
  const cursorsRaw = Array.isArray(raw.cursors) ? raw.cursors : []
  const cursors = cursorsRaw.map(parseIdeCursorEntry).filter(isIdeCursorEntry)
  const branch = stringField(raw, 'branch')
  return {
    runtime_id: runtimeId,
    connected: raw.connected === true,
    cursors,
    ...(branch ? { branch } : {}),
  }
}

function parseIdeCursorEntry(raw: unknown): IdeCursorEntry | null {
  if (!isRecord(raw)) return null
  const keeperId = stringField(raw, 'keeper_id')
  const filePath = stringField(raw, 'file_path')
  const line = numberField(raw, 'line')
  const column = numberField(raw, 'column')
  const focusMode = stringField(raw, 'focus_mode')
  const lastUpdate = numberField(raw, 'last_update')
  if (
    !keeperId
    || !filePath
    || line === null
    || line < 1
    || column === null
    || column < 0
    || !isIdeCursorFocusMode(focusMode)
    || lastUpdate === null
  ) return null

  const selectionEnd = parseSelectionEnd(raw.selection_end)
  const toolName = stringField(raw, 'tool_name')
  const turn = numberField(raw, 'turn')
  const turnId = stringField(raw, 'turn_id')
  return {
    keeper_id: keeperId,
    file_path: filePath,
    line,
    column,
    ...(selectionEnd ? { selection_end: selectionEnd } : {}),
    focus_mode: focusMode,
    last_update: lastUpdate,
    ...(toolName ? { tool_name: toolName } : {}),
    ...(turn !== null ? { turn } : {}),
    ...(turnId ? { turn_id: turnId } : {}),
  }
}

function isIdeCursorEntry(value: IdeCursorEntry | null): value is IdeCursorEntry {
  return value !== null
}

function parseSelectionEnd(raw: unknown): { readonly line: number; readonly column: number } | null {
  if (!isRecord(raw)) return null
  const line = numberField(raw, 'line')
  const column = numberField(raw, 'column')
  if (line === null || line < 1 || column === null || column < 0) return null
  return { line, column }
}

function isIdeCursorFocusMode(value: string | null): value is IdeCursorFocusMode {
  return value === 'reading'
    || value === 'editing'
    || value === 'reviewing'
    || value === 'planning'
}
