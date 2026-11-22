import { sha256 } from '@noble/hashes/sha2.js'
import { bytesToHex } from '@noble/hashes/utils.js'
import { fromByteArray, toByteArray } from 'base64-js'
import { validate as isUuid, version as uuidVersion } from 'uuid'
import { get, type GetOptions } from './core'
import { decodeExactSkillReference } from './dashboard-skills'
import { isRecord } from '../components/common/normalize'

function fields(value: unknown, required: readonly string[], optional: readonly string[] = []): Record<string, unknown> {
  if (!isRecord(value) || required.some(key => !Object.hasOwn(value, key))
      || Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) {
    throw new Error('Invalid observation fields')
  }
  return value
}
function text(value: unknown): string {
  if (typeof value !== 'string' || value.trim() === '') throw new Error('Expected nonblank result identity')
  return value
}
function string(value: unknown): string {
  if (typeof value !== 'string') throw new Error('Expected result text')
  return value
}
function integer(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw new Error('Invalid result byte count or offset')
  return value
}
function digest(value: unknown): string {
  const result = text(value)
  if (!/^[a-f0-9]{64}$/.test(result)) throw new Error('Invalid result SHA256')
  return result
}
function enumeration<const T extends readonly string[]>(value: unknown, values: T): T[number] {
  if (typeof value !== 'string' || !values.includes(value)) throw new Error('Unknown observation state')
  return value as T[number]
}
function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error('Expected observation list')
  return value
}
function boolean(value: unknown): boolean {
  if (typeof value !== 'boolean') throw new Error('Expected result boolean')
  return value
}
function hash(bytes: Uint8Array): string { return bytesToHex(sha256(bytes)) }
const utf8 = new TextEncoder()

export interface AsyncRequestIdentity { submitted_by: string; request_id: string; keeper_name: string }
export type AsyncRequestStatus = { status: 'observed'; request: Record<string, unknown> }
  | { status: 'absent' } | { status: 'unavailable'; detail: string } | { status: 'rejected'; reason: string }

/** A later parse/page failure can still report the exact source already read.
 * It never makes that source's bytes or child metadata verified. */
export class ObservationReadError extends Error {
  constructor(message: string, readonly source: string) { super(message) }
}

function identity(value: unknown): string {
  const result = text(value)
  if (result !== result.trim()) throw new Error('Request identity contains outer whitespace')
  return result
}
function finiteTime(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('Invalid async request timestamp')
  return value
}
function runId(value: unknown): string {
  const result = identity(value)
  if (!isUuid(result) || uuidVersion(result) !== 7) throw new Error('Invalid composition or owned job identity')
  return result
}
function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (isRecord(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`
  const encoded = JSON.stringify(value)
  if (encoded === undefined) throw new Error('Invalid original request context')
  return encoded
}
/** Same immutable source as Tui_decode_async_request.equal_source. Object key
 * order is transport formatting and does not create another original source. */
export function asyncRequestSourceKey(value: Extract<AsyncRequestStatus, { status: 'observed' }>): string {
  const request = value.request
  return canonicalJson([request.submitted_by, request.request_id, request.keeper_name, request.request_context])
}

function validateDependency(value: unknown): void {
  const dependency = fields(value, ['kind'], ['job_id', 'binding'])
  if (dependency.kind === 'owned_job') {
    fields(value, ['kind', 'job_id']); runId(dependency.job_id)
  } else if (dependency.kind === 'composition_result') {
    fields(value, ['kind', 'binding'])
    const binding = fields(dependency.binding, ['request_id', 'composition_run_id', 'skill_reference',
      'composition_tool', 'parent_tool_use_id', 'source_turn'], ['source_task_id'])
    identity(binding.request_id); runId(binding.composition_run_id)
    decodeExactSkillReference(binding.skill_reference)
    identity(binding.composition_tool); identity(binding.parent_tool_use_id); integer(binding.source_turn)
    if (Object.hasOwn(binding, 'source_task_id')) identity(binding.source_task_id)
  } else throw new Error('Unknown result dependency kind')
}

function decodeLogicalOwner(value: unknown): { request_id: string; generation: number } {
  const owner = fields(value, ['request_id', 'generation'])
  const generation = integer(owner.generation)
  if (generation === 0) throw new Error('Invalid logical owner generation')
  return { request_id: identity(owner.request_id), generation }
}

function validateContinuation(request: Record<string, unknown>): void {
  const continuation = fields(request.continuation, ['kind'], ['observation', 'detail'])
  switch (continuation.kind) {
    case 'not_composition': fields(continuation, ['kind']); return
    case 'unavailable': fields(continuation, ['kind', 'detail']); text(continuation.detail); return
    case 'observed': {
      fields(continuation, ['kind', 'observation'])
      const run = fields(continuation.observation, ['composition_run_id', 'source_task_id', 'owner', 'journal_version', 'observed_at', 'resolution'])
      const originalRun = runId(run.composition_run_id)
      const originalTask = run.source_task_id === null ? null : identity(run.source_task_id)
      const owner = decodeLogicalOwner(run.owner)
      digest(run.journal_version); finiteTime(run.observed_at)
      if (!isRecord(request.request_context)) throw new Error('Logical run lacks original request context')
      const context = request.request_context
      const contextTask = Object.hasOwn(context, 'source_task_id') ? identity(context.source_task_id) : null
      if (originalRun !== identity(context.composition_run_id) || originalTask !== contextTask) {
        throw new Error('Logical run or Task differs from the original request source')
      }
      if (run.resolution !== null) {
        const resolution = fields(run.resolution, ['owner', 'decision', 'requested_by', 'reason', 'resolved_at', 'expected_version', 'marker_version'])
        const resolvedOwner = decodeLogicalOwner(resolution.owner)
        enumeration(resolution.decision, ['rejected', 'cancelled'])
        identity(resolution.requested_by); text(resolution.reason); finiteTime(resolution.resolved_at)
        digest(resolution.expected_version); digest(resolution.marker_version)
        if (owner.request_id !== resolvedOwner.request_id || owner.generation !== resolvedOwner.generation) {
          throw new Error('Logical resolution belongs to another owner generation')
        }
      }
      return
    }
    default: throw new Error('Unknown async continuation observation')
  }
}

function validatePhysicalRequest(request: Record<string, unknown>): void {
  const phase = enumeration(request.status, ['queued', 'running', 'waiting_for_dependencies', 'done', 'error', 'lost', 'cancelled', 'cancelling', 'persistence_failed'])
  finiteTime(request.submitted_at)
  if (!(request.request_context === null || isRecord(request.request_context))) throw new Error('Invalid original request context')
  if (Object.hasOwn(request, 'completed_at')) finiteTime(request.completed_at)
  if (Object.hasOwn(request, 'elapsed_sec')) finiteTime(request.elapsed_sec)
  const active = phase === 'queued' || phase === 'running' || phase === 'cancelling'
  if (active === Object.hasOwn(request, 'completed_at')) throw new Error('Physical phase and completion boundary disagree')
  const hasOutcome = Object.hasOwn(request, 'ok'), hasResult = Object.hasOwn(request, 'result')
  if (phase === 'queued' || phase === 'running') {
    if (hasOutcome || hasResult) throw new Error('Active physical phase carries a completed result')
  } else if (phase === 'waiting_for_dependencies') {
    if (hasOutcome || !hasResult) throw new Error('Dependency wait outcome or retained result is invalid')
  } else if (!hasResult || !hasOutcome || request.ok !== (phase === 'done')) {
    throw new Error('Physical phase, outcome and retained result disagree')
  }
  if (phase === 'waiting_for_dependencies') {
    const dependencies = array(request.dependencies)
    if (request.worker_released !== true || dependencies.length === 0) throw new Error('Invalid physical dependency wait')
    dependencies.forEach(validateDependency)
    if (new Set(dependencies.map(canonicalJson)).size !== dependencies.length) throw new Error('Dependency wait repeats a dependency')
  } else if (Object.hasOwn(request, 'dependencies') || Object.hasOwn(request, 'worker_released')) {
    throw new Error('Dependency wait fields outside their physical phase')
  }
  if (phase === 'cancelling' || phase === 'lost' || phase === 'cancelled' || phase === 'persistence_failed') {
    if (!isRecord(request.result)) throw new Error('Physical failure lacks its original reason')
    text(request.result.reason)
  }
  validateContinuation(request)
}

export async function fetchAsyncRequestStatus(identity: AsyncRequestIdentity, opts: GetOptions = {}): Promise<AsyncRequestStatus> {
  // Target identities are exact store coordinates, not display labels.
  if ([identity.keeper_name, identity.submitted_by, identity.request_id].some(value => value.trim() !== value)) throw new Error('Request identity contains outer whitespace')
  text(identity.keeper_name)
  const query = new URLSearchParams({ submitted_by: text(identity.submitted_by), request_id: text(identity.request_id) })
  const raw = await get<unknown>(`/api/v1/async-requests/status?${query}`, opts)
  if (!isRecord(raw) || raw.schema !== 'masc.async-request-status/v1') throw new Error('Unknown async request status envelope')
  switch (raw.status) {
    case 'absent': fields(raw, ['schema', 'status']); return { status: 'absent' }
    case 'unavailable': fields(raw, ['schema', 'status', 'detail']); return { status: 'unavailable', detail: string(raw.detail) }
    case 'rejected': fields(raw, ['schema', 'status', 'reason']); return { status: 'rejected', reason: enumeration(raw.reason,
      ['invalid_base_path', 'invalid_caller', 'invalid_request_id', 'caller_mismatch', 'single_submitted_by_and_request_id_required']) }
    case 'observed': {
      if (!isRecord(raw.request)) throw new Error('Invalid physical request object')
      const request = raw.request
      if (request.request_id !== identity.request_id || request.submitted_by !== identity.submitted_by
          || request.keeper_name !== identity.keeper_name) throw new Error('Async response belongs to another request or Keeper')
      if (!(request.request_context === null || isRecord(request.request_context))) throw new Error('Invalid original request context')
      const source = asyncRequestSourceKey({ status: 'observed', request })
      try {
        fields(raw, ['schema', 'status', 'request'])
        fields(request, ['request_id', 'keeper_name', 'submitted_by', 'request_context', 'status', 'submitted_at', 'continuation'],
          ['elapsed_sec', 'completed_at', 'ok', 'result', 'dependencies', 'worker_released'])
        validatePhysicalRequest(request)
        return { status: 'observed', request }
      } catch (error) {
        if (opts.signal?.aborted) throw error
        throw new ObservationReadError(error instanceof Error ? error.message : String(error), source)
      }
    }
    default: throw new Error('Unknown async request status')
  }
}

export type OriginalToolResult = { state: 'pending' } | { state: 'unavailable'; reason: string }
  | { state: 'body'; source_id: string; body_sha256: string; recorded_bytes: number; is_error: boolean; content: string }

/** Read the exact raw-trace source, not the ledger preview. Continuations are
 * byte pages; UTF8 is decoded only after EOF and final digest verification. */
export async function fetchOriginalToolResult(keeper: string, executionId: string, opts: GetOptions = {}): Promise<OriginalToolResult> {
  text(keeper); text(executionId)
  let offset = 0
  let first: { source_id: string; body_sha256: string; recorded_bytes: number; is_error: boolean; total_bytes: number } | null = null
  let source: string | null = null
  const chunks: Uint8Array[] = []
  try {
    while (true) {
      opts.signal?.throwIfAborted()
      const query = new URLSearchParams({ execution_id: executionId, offset: String(offset) })
      if (first !== null) query.set('source_id', first.source_id)
      const raw = await get<unknown>(`/api/v1/keepers/${encodeURIComponent(keeper)}/tool-result?${query}`, opts)
      if (!isRecord(raw) || raw.keeper !== keeper || raw.execution_id !== executionId) throw new Error('Original result execution or Keeper mismatch')
      if (raw.state === 'pending' || raw.state === 'unavailable') {
        if (offset !== 0) throw new Error('Original source disappeared during continuation')
        if (raw.state === 'pending') { fields(raw, ['keeper', 'execution_id', 'state']); return { state: 'pending' } }
        fields(raw, ['keeper', 'execution_id', 'state', 'reason'])
        return { state: 'unavailable', reason: string(raw.reason) }
      }
      if (raw.state === 'page') source = JSON.stringify([digest(raw.source_id), digest(raw.body_sha256)])
      fields(raw, ['keeper', 'execution_id', 'state', 'source_id', 'body_sha256', 'recorded_bytes', 'is_error', 'page'])
      if (raw.state !== 'page') throw new Error('Unknown original result state')
      const page = fields(raw.page, ['ok', 'sha256', 'offset', 'next_offset', 'total_bytes', 'eof', 'content', 'encoding'])
      if (page.ok !== true) throw new Error('Original page is not successful')
      const identity = { source_id: digest(raw.source_id), body_sha256: digest(raw.body_sha256),
        recorded_bytes: integer(raw.recorded_bytes), is_error: boolean(raw.is_error), total_bytes: integer(page.total_bytes) }
      if (first !== null && JSON.stringify(first) !== JSON.stringify(identity)) throw new Error('Original result source changed between pages')
      first ??= identity
      const start = integer(page.offset), next = integer(page.next_offset), eof = boolean(page.eof)
      const content = string(page.content)
      const encoding = enumeration(page.encoding, ['utf-8', 'base64'])
      const bytes = encoding === 'utf-8' ? utf8.encode(content) : toByteArray(content)
      if (encoding === 'base64' && fromByteArray(bytes) !== content) throw new Error('Invalid original result base64 bytes')
      if (encoding === 'utf-8' && new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes) !== content) throw new Error('Invalid original UTF8 page')
      if (start !== offset || next < start || next > identity.total_bytes || eof !== (next === identity.total_bytes)
          || bytes.byteLength !== next - start || (!eof && next === start) || digest(page.sha256) !== identity.body_sha256) {
        throw new Error('Inconsistent original result page bounds or progress')
      }
      chunks.push(bytes)
      offset = next
      if (!eof) continue
      const body = new Uint8Array(identity.total_bytes)
      let position = 0
      for (const chunk of chunks) { body.set(chunk, position); position += chunk.byteLength }
      if (hash(body) !== identity.body_sha256) throw new Error('Original result body digest mismatch')
      const complete = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(body)
      opts.signal?.throwIfAborted()
      return { state: 'body', ...identity, content: complete }
    }
  } catch (error) {
    if (source === null || opts.signal?.aborted) throw error
    throw new ObservationReadError(error instanceof Error ? error.message : String(error), source)
  }
}
