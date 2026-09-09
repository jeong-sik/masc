import { get, type GetOptions } from './core'
import { isRecord } from '../lib/type-guards'

export interface IdeApiOptions extends GetOptions {
  readonly keeper?: string
  readonly scope?: IdeScope | null
  /** RFC-0378 §5.3b: the one wire key — the canonical codebase slug the
   *  server minted (repositories API `codebase` field). Display names and
   *  catalog ids are projection labels, not addresses. */
  readonly codebase?: string | null
}

export type IdeScope = { readonly kind: 'codebase'; readonly codebase: string }

export type IdeScopeOptions = Pick<IdeApiOptions, 'scope' | 'codebase'>

export type IdeEventKind = 'tool' | 'turn'

export interface IdeEventsOptions extends IdeApiOptions {
  readonly kind?: IdeEventKind | 'all'
  readonly keeperId?: string
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

function trimmedNonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

export function ideScopeFromCodebase(codebase: string | null | undefined): IdeScope | null {
  const trimmed = trimmedNonEmpty(codebase)
  return trimmed ? { kind: 'codebase', codebase: trimmed } : null
}

function resolveIdeScope(opts: IdeScopeOptions): IdeScope | null {
  const candidates: IdeScope[] = []
  if (opts.scope) candidates.push(opts.scope)
  const codebaseScope = ideScopeFromCodebase(opts.codebase)
  if (codebaseScope) candidates.push(codebaseScope)
  if (candidates.length > 1) {
    throw new Error('IDE scope must resolve to exactly one codebase')
  }
  return candidates[0] ?? null
}

export function appendIdeScopeParams(params: URLSearchParams, opts: IdeScopeOptions): void {
  const scope = resolveIdeScope(opts)
  if (!scope) return
  params.set('codebase', scope.codebase)
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

export async function fetchIdePresence(
  opts: IdeApiOptions = {},
): Promise<unknown> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  const raw = await get<unknown>(`/api/v1/ide/presence?${params.toString()}`, opts)
  if (!isRecord(raw) || raw.ok !== true) return null
  return raw.data
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

