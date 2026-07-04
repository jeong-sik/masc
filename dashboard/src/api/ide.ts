import { get, post, fetchWithTimeout, type GetOptions } from './core'
import {
  parseIdeAnnotations,
  parseIdeCodeRegions,
  type IdeAnnotation,
  type IdeCodeRegion,
  type AnnotationKind,
} from './schemas/ide-annotations'
import { isRecord } from '../lib/type-guards'

export type { IdeAnnotation, IdeCodeRegion, AnnotationKind } from './schemas/ide-annotations'

export interface IdeApiOptions extends GetOptions {
  readonly keeper?: string
  readonly repoId?: string | null
}

export type IdeEventKind = 'tool' | 'turn' | 'pr'

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
  readonly command_descriptor: unknown
}

export interface IdeTurnEvent extends IdeBridgeEventBase {
  readonly type: 'turn'
  readonly phase: string
  readonly model_used: string | null
  readonly tools_used: ReadonlyArray<string>
  readonly stop_reason: string | null
  readonly duration_ms: number | null
}

export interface IdePrEvent extends IdeBridgeEventBase {
  readonly type: 'pr'
  readonly pr_number: number
  readonly pull_request_url: string
  readonly pr_title: string
  readonly pr_state: string
  readonly repo: string
  readonly comment_count: number
  readonly review_status: string | null
}

export type IdeBridgeEvent = IdeToolEvent | IdeTurnEvent | IdePrEvent

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
  readonly board_post_id?: string
  readonly comment_id?: string
  readonly pr_id?: string
  readonly git_ref?: string
  readonly log_id?: string
  readonly session_id?: string
  readonly operation_id?: string
  readonly worker_run_id?: string
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

function appendWorkspaceParams(
  params: URLSearchParams,
  opts: IdeApiOptions,
): void {
  if (opts.keeper) params.set('keeper', opts.keeper)
  if (opts.repoId) params.set('repo_id', opts.repoId)
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
  if (!isRecord(raw) || raw.ok !== true) return []
  return parseIdeAnnotations(raw.data)
}

export async function createIdeAnnotation(
  input: CreateAnnotationInput,
  opts: IdeApiOptions = {},
): Promise<IdeAnnotation | null> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const raw = await post<unknown>(`/api/v1/ide/annotations${query}`, input)
  if (!isRecord(raw) || raw.ok !== true) return null
  return parseIdeAnnotations([raw.data])[0] ?? null
}

export async function deleteIdeAnnotation(
  id: string,
  opts: IdeApiOptions = {},
): Promise<boolean> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const path = `/api/v1/ide/annotations/${encodeURIComponent(id)}${query}`
  try {
    const res = await fetchWithTimeout(path, { method: 'DELETE' }, 15_000)
    return res.ok
  } catch {
    return false
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
  if (!isRecord(raw) || raw.ok !== true) return []
  return parseIdeCodeRegions(raw.data)
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
  if (!isRecord(raw) || raw.ok !== true) return null
  return parseIdeCursorSnapshot(raw.data)
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
  if (!isRecord(raw) || raw.ok !== true || !isRecord(raw.data)) return []
  const events = raw.data.events
  return Array.isArray(events) ? events.map(parseIdeBridgeEvent).filter(isIdeBridgeEvent) : []
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
      command_descriptor: raw.command_descriptor ?? null,
    }
  }

  if (type === 'turn') {
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

  const prNumber = numberField(raw, 'pr_number')
  const pullRequestUrl = stringField(raw, 'pull_request_url') ?? ''
  const prTitle = stringField(raw, 'pr_title') ?? ''
  const prState = stringField(raw, 'pr_state') ?? ''
  const repo = stringField(raw, 'repo') ?? ''
  const commentCount = numberField(raw, 'comment_count')
  if (prNumber === null || commentCount === null) return null
  return {
    type,
    keeper_id: keeperId,
    turn_id: turnId,
    timestamp_ms: timestampMs,
    pr_number: prNumber,
    pull_request_url: pullRequestUrl,
    pr_title: prTitle,
    pr_state: prState,
    repo,
    comment_count: commentCount,
    review_status: stringField(raw, 'review_status'),
  }
}

function isIdeBridgeEvent(value: IdeBridgeEvent | null): value is IdeBridgeEvent {
  return value !== null
}

function isIdeEventKind(value: string | null): value is IdeEventKind {
  return value === 'tool' || value === 'turn' || value === 'pr'
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
