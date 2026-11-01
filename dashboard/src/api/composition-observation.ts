import { sha256 } from '@noble/hashes/sha2.js'
import { bytesToHex } from '@noble/hashes/utils.js'
import { fromByteArray, toByteArray } from 'base64-js'
import { get, type GetOptions } from './core'
import { decodeExactSkillReference, decodeSkillActivationPayload, type SkillReference } from './dashboard-skills'
import { skillActivationFrameSha256, type DashboardSkillActivation } from './dashboard-tools-prompts'
import { fetchVerifiedToolBlobText } from './verified-tool-blob'
import { parseToolBlobMarker, type ToolBlobMarker } from '../lib/tool-blob-marker'
import { isRecord } from '../components/common/normalize'

const MANIFEST_MIME = 'application/vnd.masc.tool-result-manifest+json'
const MANIFEST_SCHEMA = 'masc.tool-result-artifact-manifest.v1'
const dispositions = ['completed', 'deferred', 'failed'] as const
const childDispositions = ['not_started', 'admission_rejected', ...dispositions, 'partially_settled'] as const
const effects = ['proven_pre_effect', 'proven_post_effect', 'effect_outcome_unknown'] as const

export interface NestedNode {
  node_id: string
  origin: { phase: 'arguments' | 'submission' | 'result' } | { source: string }
  disposition: typeof dispositions[number] | null
  tool_use_id: string | null
  effect_disposition: typeof effects[number] | null
  validation_error: unknown
}
export interface NestedChild {
  alias: string
  reference: SkillReference
  execution: 'inline' | 'async'
  arguments: unknown
  admission: { kind: 'not_attempted' } | { kind: 'rejected'; rejection: unknown }
    | { kind: 'recorded'; tool_use_id: string; frame_sha256: string; activation: DashboardSkillActivation }
  disposition: typeof childDispositions[number]
  cause: unknown
  nodes: readonly NestedNode[]
  exports: readonly { name: string; node_id: string; pointer: string;
    value: { available: true; value: unknown } | { available: false; error: unknown } }[]
}
export type NestedReading = { kind: 'absent' } | { kind: 'observed'; children: readonly NestedChild[] }
  | { kind: 'stored'; reference: ToolBlobMarker } | { kind: 'invalid'; detail: string }

function fields(value: unknown, required: readonly string[], optional: readonly string[] = []): Record<string, unknown> {
  if (!isRecord(value) || required.some(key => !Object.hasOwn(value, key))
      || Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) {
    throw new Error('Invalid nested result fields')
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
  if (typeof value !== 'string' || !values.includes(value)) throw new Error('Unknown nested result state')
  return value as T[number]
}
function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error('Expected nested result list')
  return value
}
function boolean(value: unknown): boolean {
  if (typeof value !== 'boolean') throw new Error('Expected result boolean')
  return value
}
function hash(bytes: Uint8Array): string { return bytesToHex(sha256(bytes)) }
const utf8 = new TextEncoder()

function blobReference(value: unknown): ToolBlobMarker {
  const wrapper = fields(value, ['_blob'])
  const ref = fields(wrapper._blob, ['sha256', 'bytes', 'mime', 'preview'])
  return { sha256: digest(ref.sha256), bytes: integer(ref.bytes), mime: text(ref.mime), preview: string(ref.preview) }
}
// The canonical manifest reserves _blob throughout structured_content. This
// validates references; it does not search user output for nested execution.
function validateBlobReferences(value: unknown): void {
  if (Array.isArray(value)) value.forEach(validateBlobReferences)
  else if (isRecord(value)) {
    if (Object.hasOwn(value, '_blob')) blobReference(value)
    else Object.values(value).forEach(validateBlobReferences)
  }
}
function manifestData(value: unknown): unknown {
  const manifest = fields(value, ['schema', 'content', 'structured_content'])
  if (manifest.schema !== MANIFEST_SCHEMA) throw new Error('Unknown result manifest')
  string(manifest.content)
  validateBlobReferences(manifest.structured_content)
  return manifest.structured_content
}

function decodeNode(value: unknown): NestedNode {
  const node = fields(value, ['node_id', 'settled', 'disposition'],
    ['phase', 'source', 'tool_use_id', 'failure_effect_disposition', 'output_validation_error'])
  let origin: NestedNode['origin']
  if (Object.hasOwn(node, 'phase') && !Object.hasOwn(node, 'source')) {
    origin = { phase: enumeration(node.phase, ['arguments', 'submission', 'result']) }
  } else if (!Object.hasOwn(node, 'phase') && Object.hasOwn(node, 'source')) origin = { source: text(node.source) }
  else throw new Error('Unknown or ambiguous child node origin')
  const settled = boolean(node.settled)
  const disposition = settled ? enumeration(node.disposition, dispositions) : null
  if ((!settled && (node.disposition !== null || Object.hasOwn(node, 'tool_use_id')))
      || (settled && !Object.hasOwn(node, 'tool_use_id'))) throw new Error('Child settlement and occurrence disagree')
  return { node_id: text(node.node_id), origin, disposition,
    tool_use_id: settled ? text(node.tool_use_id) : null,
    effect_disposition: node.failure_effect_disposition == null ? null : enumeration(node.failure_effect_disposition, effects),
    validation_error: node.output_validation_error ?? null }
}

function decodeChild(value: unknown, runId: string | null): NestedChild {
  const child = fields(value, ['scope', 'admission', 'disposition', 'cause', 'nodes', 'exports'])
  const scope = fields(child.scope, ['alias', 'reference', 'arguments', 'scope', 'exports'])
  const alias = text(scope.alias)
  const reference = decodeExactSkillReference(scope.reference)
  if (!isRecord(scope.scope)) throw new Error('Invalid child execution scope')
  const execution = enumeration(scope.scope.kind, ['inline', 'async'])
  const args = fields(scope.arguments, ['kind'], ['value', 'input'])
  if (!(args.kind === 'fixed' && Object.hasOwn(args, 'value') && !Object.hasOwn(args, 'input'))
      && !(args.kind === 'upstream' && Object.hasOwn(args, 'input') && !Object.hasOwn(args, 'value'))) {
    throw new Error('Unknown declared child argument form')
  }
  let admission: NestedChild['admission']
  if (child.admission === null) admission = { kind: 'not_attempted' }
  else if (isRecord(child.admission) && Object.hasOwn(child.admission, 'rejection')) {
    admission = { kind: 'rejected', rejection: fields(child.admission, ['rejection']).rejection }
  } else {
    const recorded = fields(child.admission, ['skill_tool_use_id', 'activation', 'activation_frame_sha256'])
    const activation = decodeSkillActivationPayload(recorded.activation)
    const toolUseId = text(recorded.skill_tool_use_id)
    const frame = digest(recorded.activation_frame_sha256)
    const invocation = activation.invocation
    if (invocation.kind !== 'nested_composition' || invocation.scope.alias !== alias
        || (runId !== null && invocation.scope.composition_run_id !== runId)
        || activation.skill_tool_use_id !== toolUseId
        || activation.identity.source_id !== reference.identity.source_id
        || activation.identity.package_id !== reference.identity.package_id
        || activation.identity.name !== reference.identity.name
        || activation.content_revision !== reference.content_revision
        || skillActivationFrameSha256(activation) !== frame) {
      throw new Error('Child admission differs from its original scope, occurrence or activation frame')
    }
    admission = { kind: 'recorded', tool_use_id: toolUseId, frame_sha256: frame, activation }
  }
  if (!isRecord(child.exports)) throw new Error('Invalid observed child exports')
  const observed = child.exports
  const exports = array(scope.exports).map(value => {
    const route = fields(value, ['name', 'node', 'pointer'])
    const name = text(route.name)
    if (!Object.hasOwn(observed, name)) throw new Error('Missing observed child export')
    const item = fields(observed[name], ['available'], ['value', 'error'])
    let output: NestedChild['exports'][number]['value']
    if (item.available === true && Object.hasOwn(item, 'value') && !Object.hasOwn(item, 'error')) output = { available: true, value: item.value }
    else if (item.available === false && !Object.hasOwn(item, 'value') && Object.hasOwn(item, 'error')) output = { available: false, error: item.error }
    else throw new Error('Invalid child export availability')
    return { name, node_id: text(route.node), pointer: string(route.pointer), value: output }
  })
  return { alias, reference, execution, arguments: scope.arguments, admission,
    disposition: enumeration(child.disposition, childDispositions), cause: child.cause,
    nodes: array(child.nodes).map(decodeNode), exports }
}

function direct(value: unknown): NestedReading {
  if (!isRecord(value) || !Object.hasOwn(value, 'nested_scopes')) return { kind: 'absent' }
  const runId = Object.hasOwn(value, 'composition_run_id') ? text(value.composition_run_id) : null
  return { kind: 'observed', children: array(value.nested_scopes).map(child => decodeChild(child, runId)) }
}

/** Only canonical root metadata or the explicit structured/failure envelope is
 * inspected. Prepared definitions and arbitrary node output are not execution. */
export function decodeNestedData(value: unknown): NestedReading {
  try {
    const reading = direct(value)
    if (reading.kind !== 'absent') return reading
    if (!isRecord(value)) return reading
    if (value.schema === MANIFEST_SCHEMA) return direct(manifestData(value))
    if (Object.hasOwn(value, 'artifact_manifest')) {
      const envelope = fields(value, ['artifact_manifest', 'structured_content'], ['content'])
      const reference = blobReference(envelope.artifact_manifest)
      if (reference.mime !== MANIFEST_MIME) throw new Error('Invalid structured result manifest reference')
      return { kind: 'stored', reference }
    }
    if (Object.hasOwn(value, 'masc.tool_disposition')) {
      const envelope = fields(value, ['message', 'masc.tool_disposition', 'failure_class'], ['next_move', 'data', 'masc.payload'])
      string(envelope.message)
      enumeration(envelope.failure_class, ['dependency_unavailable', 'transient_error', 'policy_rejection', 'runtime_failure', 'workflow_rejection', 'operator_cancelled'])
      if (envelope['masc.tool_disposition'] !== 'failed') throw new Error('Invalid original failure result envelope')
      return direct(envelope.data)
    }
    return reading
  } catch (error) { return { kind: 'invalid', detail: error instanceof Error ? error.message : String(error) } }
}

export function decodeNestedContent(content: string): NestedReading {
  const marker = parseToolBlobMarker(content)
  if (marker !== null) {
    try {
      digest(marker.sha256); integer(marker.bytes)
      return marker.mime === MANIFEST_MIME ? { kind: 'stored', reference: marker } : { kind: 'absent' }
    } catch (error) { return { kind: 'invalid', detail: String(error) } }
  }
  if (content.startsWith('[masc:blob ')) return { kind: 'invalid', detail: 'Invalid retained result marker' }
  try { return decodeNestedData(JSON.parse(content)) }
  catch { return { kind: 'absent' } }
}

export async function resolveNestedReading(reading: NestedReading, signal?: AbortSignal): Promise<NestedReading> {
  if (reading.kind !== 'stored') return reading
  try {
    if (reading.reference.mime !== MANIFEST_MIME) throw new Error('Invalid retained manifest reference MIME')
    // The artifact store returns a text/plain transport DTO; media meaning is
    // owned by the exact reference and the verified manifest schema.
    const content = await fetchVerifiedToolBlobText(reading.reference, signal)
    return direct(manifestData(JSON.parse(content)))
  } catch (error) {
    if (signal?.aborted) throw error
    return { kind: 'invalid', detail: error instanceof Error ? error.message : String(error) }
  }
}

export interface AsyncRequestIdentity { submitted_by: string; request_id: string; keeper_name: string }
export type AsyncRequestStatus = { status: 'observed'; request: Record<string, unknown>; nested: NestedReading }
  | { status: 'absent' } | { status: 'unavailable'; detail: string } | { status: 'rejected'; reason: string }

export async function fetchAsyncRequestStatus(identity: AsyncRequestIdentity, opts: GetOptions = {}): Promise<AsyncRequestStatus> {
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
      fields(raw, ['schema', 'status', 'request'])
      const request = fields(raw.request, ['request_id', 'keeper_name', 'submitted_by', 'request_context', 'status', 'submitted_at', 'continuation'],
        ['elapsed_sec', 'completed_at', 'ok', 'result', 'dependencies', 'worker_released'])
      if (request.request_id !== identity.request_id || request.submitted_by !== identity.submitted_by
          || request.keeper_name !== identity.keeper_name) throw new Error('Async response belongs to another request or Keeper')
      enumeration(request.status, ['queued', 'running', 'waiting_for_dependencies', 'done', 'error', 'lost', 'cancelled', 'cancelling', 'persistence_failed'])
      if (typeof request.submitted_at !== 'number' || !Number.isFinite(request.submitted_at)
          || !(request.request_context === null || isRecord(request.request_context)) || !isRecord(request.continuation)) throw new Error('Invalid async request observation')
      for (const key of ['completed_at', 'elapsed_sec']) {
        if (Object.hasOwn(request, key) && (typeof request[key] !== 'number' || !Number.isFinite(request[key]))) throw new Error('Invalid async request timestamp')
      }
      for (const key of ['ok', 'worker_released']) if (Object.hasOwn(request, key)) boolean(request[key])
      if (Object.hasOwn(request, 'dependencies')) array(request.dependencies)
      const continuation = fields(request.continuation, ['kind'], ['observation', 'detail'])
      switch (continuation.kind) {
        case 'not_composition': fields(continuation, ['kind']); break
        case 'observed': fields(continuation, ['kind', 'observation']); break
        case 'unavailable': fields(continuation, ['kind', 'detail']); string(continuation.detail); break
        default: throw new Error('Unknown async continuation observation')
      }
      const reading = typeof request.result === 'string' ? decodeNestedContent(request.result) : decodeNestedData(request.result)
      return { status: 'observed', request, nested: await resolveNestedReading(reading, opts.signal) }
    }
    default: throw new Error('Unknown async request status')
  }
}

export type OriginalToolResult = { state: 'pending' } | { state: 'unavailable'; reason: string }
  | { state: 'body'; source_id: string; body_sha256: string; recorded_bytes: number; is_error: boolean; content: string; nested: NestedReading }

/** Read the exact raw-trace source, not the ledger preview. Continuations are
 * byte pages; UTF8 is decoded only after EOF and final digest verification. */
export async function fetchOriginalToolResult(keeper: string, executionId: string, opts: GetOptions = {}): Promise<OriginalToolResult> {
  text(keeper); text(executionId)
  let offset = 0
  let first: { source_id: string; body_sha256: string; recorded_bytes: number; is_error: boolean; total_bytes: number } | null = null
  const chunks: Uint8Array[] = []
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
    return { state: 'body', ...identity, content: complete,
      nested: await resolveNestedReading(decodeNestedContent(complete), opts.signal) }
  }
}
