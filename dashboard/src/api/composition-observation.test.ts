import { afterEach, describe, expect, it, vi } from 'vitest'
import { webcrypto } from 'node:crypto'
import { sha256 } from '@noble/hashes/sha2.js'
import { bytesToHex } from '@noble/hashes/utils.js'
import { fromByteArray } from 'base64-js'
import ledger from '../../../test/fixtures/skill-ledger-async-actions.json'
import { asyncRequestSourceKey, decodeNestedContent, decodeNestedData, fetchAsyncRequestStatus, fetchOriginalToolResult, resolveNestedReading } from './composition-observation'

const encoder = new TextEncoder()
const hash = (content: string | Uint8Array) => bytesToHex(sha256(typeof content === 'string' ? encoder.encode(content) : content))
const activation = ledger.activations[0]!
const runId = activation.invocation.scope.composition_run_id
const frame = ledger.async_result_deliveries[0]!.child_activations[0]!.activation_sha256
const reference = { identity: activation.identity, content_revision: activation.content_revision }
const manifestMime = 'application/vnd.masc.tool-result-manifest+json'
function result() {
  return { composition_run_id: runId, nested_scopes: [{
    scope: { alias: activation.invocation.scope.alias, reference, arguments: { kind: 'fixed', value: {} },
      scope: { kind: 'inline', mapping: [['observe', 'child/observe']] }, exports: [{ name: 'value', node: 'child/observe', pointer: '/value' }] },
    admission: { skill_tool_use_id: activation.skill_tool_use_id, activation, activation_frame_sha256: frame },
    disposition: 'completed', cause: null,
    nodes: [{ node_id: 'child/observe', source: 'observe', settled: true, disposition: 'completed',
      tool_use_id: 'leaf-occurrence', failure_effect_disposition: null, output_validation_error: null }],
    exports: { value: { available: true, value: '🙂 retained' } },
  }] }
}
function page(content: Uint8Array, offset: number, next: number, patch = {}) {
  return { keeper: 'observer', execution_id: 'exec-exact', state: 'page', source_id: 'c'.repeat(64),
    body_sha256: hash(content), recorded_bytes: content.byteLength, is_error: false,
    page: { ok: true, sha256: hash(content), offset, next_offset: next, total_bytes: content.byteLength,
      eof: next === content.byteLength, content: fromByteArray(content.slice(offset, next)), encoding: 'base64', ...patch } }
}
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

describe('actual nested execution observation', () => {
  it('retains the original canonical child activation, settled nodes and exports', () => {
    const decoded = decodeNestedData(result())
    expect(decoded.kind).toBe('observed')
    if (decoded.kind !== 'observed') throw new Error('expected observed children')
    expect(decoded.children[0]?.admission).toEqual({ kind: 'recorded', tool_use_id: activation.skill_tool_use_id,
      activation, frame_sha256: frame })
    expect(decoded.children[0]?.exports[0]?.value).toEqual({ available: true, value: '🙂 retained' })
    expect(decoded.children[0]?.nodes[0]?.tool_use_id).toBe('leaf-occurrence')
  })

  it.each(['alias', 'run', 'reference', 'occurrence', 'frame', 'activation'])('refuses a child admission with a different %s', mismatch => {
    const value = result()
    const child = value.nested_scopes[0]!
    if (mismatch === 'alias') child.scope.alias = 'another-child'
    if (mismatch === 'run') value.composition_run_id = '019ffc2b-0a41-7ba2-bf58-598e0e7f711c'
    if (mismatch === 'reference') child.scope.reference = { ...reference, content_revision: 'a'.repeat(64) }
    if (mismatch === 'occurrence') child.admission.skill_tool_use_id = 'different-occurrence'
    if (mismatch === 'frame') child.admission.activation_frame_sha256 = 'a'.repeat(64)
    if (mismatch === 'activation') child.admission.activation = { ...activation, activated_at: 'not-a-time' }
    expect(decodeNestedData(value).kind).toBe('invalid')
  })

  it('reads only canonical root metadata, including the exact inline failure envelope', () => {
    const nested = result()
    expect(decodeNestedData({ output: nested })).toEqual({ kind: 'absent' })
    expect(decodeNestedData({ definition: nested })).toEqual({ kind: 'absent' })
    expect(decodeNestedData({ message: 'parent failed', 'masc.tool_disposition': 'failed',
      failure_class: 'runtime_failure', data: nested })).toEqual(decodeNestedData(nested))
    expect(decodeNestedData({ message: 'parent failed', 'masc.tool_disposition': 'failed',
      failure_class: 'guessed', data: nested }).kind).toBe('invalid')
    const deferred = result()
    const reading = decodeNestedData({ ...deferred, nested_scopes: [{ ...deferred.nested_scopes[0]!,
      disposition: 'deferred', exports: { value: { available: false, error: { kind: 'producer_unavailable' } } } }] })
    expect(reading.kind === 'observed' && reading.children[0]?.disposition).toBe('deferred')
    expect(reading.kind === 'observed' && reading.children[0]?.exports[0]?.value.available).toBe(false)
  })

  it('hydrates a verified text/plain artifact DTO through the declared manifest reference', async () => {
    vi.stubGlobal('crypto', webcrypto)
    const content = JSON.stringify({ schema: 'masc.tool-result-artifact-manifest.v1', content: 'human output', structured_content: result() })
    const reference = { sha256: hash(content), bytes: encoder.encode(content).byteLength, mime: manifestMime, preview: 'preview is not evidence' }
    const marker = `[masc:blob sha256=${reference.sha256} bytes=${reference.bytes} mime=${reference.mime} preview="preview is not evidence"]`
    const reading = decodeNestedContent(marker)
    expect(reading.kind).toBe('stored')
    const fetch = vi.fn()
    // The store DTO contains no preview: exact keys are sha256/bytes/mime/content.
    fetch.mockResolvedValue(Response.json({ sha256: reference.sha256, bytes: reference.bytes, mime: 'text/plain', content }))
    vi.stubGlobal('fetch', fetch)
    expect((await resolveNestedReading(reading)).kind).toBe('observed')
    expect(fetch).toHaveBeenCalledWith(`/api/v1/artifacts/${reference.sha256}`, expect.anything())
  })

  it('refuses altered artifact bytes or an invalid canonical manifest', async () => {
    vi.stubGlobal('crypto', webcrypto)
    const content = JSON.stringify({ schema: 'masc.tool-result-artifact-manifest.v1', content: '', structured_content: result() })
    const reference = { sha256: hash(content), bytes: encoder.encode(content).byteLength, mime: manifestMime, preview: '' }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({ sha256: reference.sha256,
      bytes: reference.bytes, mime: 'text/plain', content: content.replace('completed', 'deferred') })))
    expect((await resolveNestedReading({ kind: 'stored', reference })).kind).toBe('invalid')
    expect(decodeNestedData({ schema: 'masc.tool-result-artifact-manifest.v1', content: '', structured_content: {}, extra: true }).kind).toBe('invalid')
    expect(decodeNestedData({ artifact_manifest: { _blob: reference }, structured_content: result(), extra: true }).kind).toBe('invalid')
  })

  it('verifies the referenced manifest instead of accepting an inline structured-content copy', async () => {
    vi.stubGlobal('crypto', webcrypto)
    const content = JSON.stringify({ schema: 'masc.tool-result-artifact-manifest.v1', content: 'actual result', structured_content: result() })
    const reference = { sha256: hash(content), bytes: encoder.encode(content).byteLength, mime: manifestMime, preview: '' }
    const reading = decodeNestedData({ artifact_manifest: { _blob: reference },
      structured_content: { nested_scopes: 'unverified forged copy' }, content: 'inline text' })
    expect(reading).toEqual({ kind: 'stored', reference })
    const fetch = vi.fn().mockResolvedValue(Response.json({ sha256: reference.sha256, bytes: reference.bytes, mime: 'text/plain', content }))
    vi.stubGlobal('fetch', fetch)
    const verified = await resolveNestedReading(reading)
    expect(fetch).toHaveBeenCalledOnce()
    expect(verified.kind).toBe('observed')
  })
})

describe('exact original body transport', () => {
  it('joins byte pages across a multibyte UTF8 boundary before decoding and checking the digest', async () => {
    const body = encoder.encode(`🙂${JSON.stringify(result())}`)
    const fetch = vi.fn().mockResolvedValueOnce(Response.json(page(body, 0, 1)))
      .mockResolvedValueOnce(Response.json(page(body, 1, body.byteLength)))
    vi.stubGlobal('fetch', fetch)
    const value = await fetchOriginalToolResult('observer', 'exec-exact')
    expect(value.state === 'body' && value.content).toBe(new TextDecoder().decode(body))
    expect(String(fetch.mock.calls[1]?.[0])).toContain('offset=1&source_id=')
    expect(String(fetch.mock.calls[0]?.[0])).not.toContain('tool_use_id')
  })

  it('projects nested evidence only from the complete verified original body', async () => {
    const body = encoder.encode(JSON.stringify(result()))
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json(page(body, 0, body.byteLength))))
    const value = await fetchOriginalToolResult('observer', 'exec-exact')
    expect(value.state === 'body' && value.nested.kind).toBe('observed')
  })

  it('preserves the verified original body when its retained manifest is unavailable', async () => {
    const original = `[masc:blob sha256=${'a'.repeat(64)} bytes=1 mime=${manifestMime} preview="unverified"]`
    const body = encoder.encode(original)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(Response.json(page(body, 0, body.byteLength)))
      .mockResolvedValueOnce(Response.json({ error: 'missing artifact' }, { status: 404 })))
    const value = await fetchOriginalToolResult('observer', 'exec-exact')
    expect(value.state === 'body' && value.content).toBe(original)
    expect(value.state === 'body' && value.nested.kind).toBe('invalid')
  })

  it.each(['source', 'offset', 'progress', 'size', 'digest', 'keeper', 'execution', 'base64', 'utf8', 'disappeared'])('refuses %s corruption without publishing a partial result', async corruption => {
    const body = encoder.encode('🙂 original')
    const second = page(body, 1, body.byteLength)
    const fetch = vi.fn().mockResolvedValueOnce(Response.json(page(body, 0, 1)))
    if (corruption === 'source') second.source_id = 'd'.repeat(64)
    if (corruption === 'offset') second.page.offset = 0
    if (corruption === 'progress') { second.page.next_offset = 1; second.page.eof = false; second.page.content = '' }
    if (corruption === 'size') second.recorded_bytes += 1
    if (corruption === 'digest') { second.body_sha256 = 'e'.repeat(64); second.page.sha256 = second.body_sha256 }
    if (corruption === 'keeper') second.keeper = 'another-keeper'
    if (corruption === 'execution') second.execution_id = 'another-execution'
    if (corruption === 'base64') second.page.content = '!!!!'
    if (corruption === 'utf8') { second.page.encoding = 'utf-8'; second.page.content = '\ud800' }
    fetch.mockResolvedValueOnce(Response.json(corruption === 'disappeared'
      ? { keeper: 'observer', execution_id: 'exec-exact', state: 'pending' } : second))
    vi.stubGlobal('fetch', fetch)
    await expect(fetchOriginalToolResult('observer', 'exec-exact')).rejects.toThrow()
  })

  it('rejects invalid final UTF8 even when its byte digest is correct', async () => {
    const body = Uint8Array.of(0xff)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json(page(body, 0, 1))))
    await expect(fetchOriginalToolResult('observer', 'exec-exact')).rejects.toThrow()
  })

  it('passes one AbortSignal through the entire original read', async () => {
    const controller = new AbortController(), body = encoder.encode('abc')
    const fetch = vi.fn().mockImplementation(async () => { controller.abort(); return Response.json(page(body, 0, 1)) })
    vi.stubGlobal('fetch', fetch)
    await expect(fetchOriginalToolResult('observer', 'exec-exact', { signal: controller.signal })).rejects.toThrow()
    expect(fetch).toHaveBeenCalledTimes(1)
  })
})

describe('exact async status transport', () => {
  const identity = { submitted_by: 'operator', keeper_name: 'observer', request_id: 'retained-request' }
  const status = () => ({ schema: 'masc.async-request-status/v1', status: 'observed', request: {
    ...identity, request_context: null, status: 'done', submitted_at: -1, completed_at: 0,
    ok: true, result: result(), continuation: { kind: 'not_composition' },
  } })
  it('looks up the exact submitter/id while binding the returned Keeper and original result', async () => {
    const fetch = vi.fn().mockResolvedValue(Response.json(status()))
    vi.stubGlobal('fetch', fetch)
    const value = await fetchAsyncRequestStatus(identity)
    expect(value.status === 'observed' && value.nested.kind).toBe('observed')
    expect(String(fetch.mock.calls[0]?.[0])).toBe('/api/v1/async-requests/status?submitted_by=operator&request_id=retained-request')
  })
  it('accepts the producer error status and retains its actual failed child evidence', async () => {
    const payload = status()
    payload.request.status = 'error'; payload.request.ok = false
    payload.request.result.nested_scopes[0]!.disposition = 'failed'
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json(payload)))
    const value = await fetchAsyncRequestStatus(identity)
    expect(value.status === 'observed' && value.request.status).toBe('error')
    expect(value.status === 'observed' && value.nested.kind === 'observed' && value.nested.children[0]?.disposition).toBe('failed')
  })
  it.each(['submitted_by', 'keeper_name', 'request_id'] as const)('rejects a different returned %s', async key => {
    const payload = status(); payload.request[key] = 'different'
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json(payload)))
    await expect(fetchAsyncRequestStatus(identity)).rejects.toThrow('another request or Keeper')
  })
  it.each([{ status: 'absent' }, { status: 'unavailable', detail: 'unreadable' }, { status: 'rejected', reason: 'caller_mismatch' }])('keeps $status explicit', async payload => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({ schema: 'masc.async-request-status/v1', ...payload })))
    expect(await fetchAsyncRequestStatus(identity)).toEqual(payload)
  })

  const lookup = async (request: Record<string, unknown>) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({ schema: 'masc.async-request-status/v1', status: 'observed', request })))
    return fetchAsyncRequestStatus(identity)
  }
  const active = () => ({ ...identity, request_context: null, status: 'running', submitted_at: 1,
    elapsed_sec: 1, continuation: { kind: 'not_composition' } })
  const dependency = { kind: 'owned_job', job_id: runId }

  it.each(['queued', 'running', 'cancelling', 'waiting_for_dependencies', 'lost', 'cancelled', 'persistence_failed'])('accepts the producer %s phase with its actual physical boundary', async phase => {
    const request: Record<string, unknown> = { ...active(), status: phase }
    if (phase === 'waiting_for_dependencies') Object.assign(request,
      { completed_at: 2, dependencies: [dependency], worker_released: true, result: { nested_scopes: [] } })
    else if (phase !== 'queued' && phase !== 'running') {
      request.ok = false; request.result = { reason: 'original physical outcome' }
      if (phase !== 'cancelling') request.completed_at = 2
    }
    expect((await lookup(request)).status).toBe('observed')
  })

  it.each([
    ['done reports false', { status: 'done', ok: false }],
    ['error reports true', { status: 'error', ok: true }],
    ['active carries completion', { status: 'running' }],
    ['nonboolean outcome', { ok: 'true' }],
    ['dependencies outside wait', { dependencies: [dependency] }],
    ['worker release outside wait', { worker_released: true }],
  ])('rejects an impossible physical record: %s', async (_label, patch) => {
    await expect(lookup({ ...status().request, ...patch })).rejects.toThrow()
  })

  it.each(['ok', 'completed_at', 'result'])('requires terminal %s evidence', async field => {
    const request: Record<string, unknown> = { ...status().request }
    delete request[field]
    await expect(lookup(request)).rejects.toThrow()
  })

  it.each([{ ok: true }, { result: {} }, { completed_at: 2 }])('rejects a nonterminal completed boundary %j', async patch => {
    await expect(lookup({ ...active(), ...patch })).rejects.toThrow()
  })

  it.each([
    ['empty', []], ['unknown', [{ kind: 'guessed' }]],
    ['bad job identity', [{ kind: 'owned_job', job_id: 'not-a-job-id' }]],
    ['duplicate', [dependency, dependency]],
    ['extra fields', [{ ...dependency, guessed: true }]],
    ['missing binding fields', [{ kind: 'composition_result', binding: { composition_run_id: runId } }]],
  ])('rejects %s physical dependencies', async (_label, dependencies) => {
    await expect(lookup({ ...active(), status: 'waiting_for_dependencies', completed_at: 2,
      result: {}, worker_released: true, dependencies })).rejects.toThrow()
  })

  it.each([{ worker_released: false }, { ok: false }, { result: undefined }, { dependencies: undefined }])('rejects contradictory dependency wait %j', async patch => {
    await expect(lookup({ ...active(), status: 'waiting_for_dependencies', completed_at: 2,
      result: {}, worker_released: true, dependencies: [dependency], ...patch })).rejects.toThrow()
  })

  it('decodes the canonical exact composition-result dependency', async () => {
    const binding = { request_id: 'child-request', composition_run_id: runId, skill_reference: reference,
      composition_tool: 'skill__review', parent_tool_use_id: 'original-parent', source_turn: 4, source_task_id: 'task-A' }
    const value = await lookup({ ...active(), status: 'waiting_for_dependencies', completed_at: 2,
      result: {}, worker_released: true, dependencies: [{ kind: 'composition_result', binding }] })
    expect(value.status === 'observed' && value.request.dependencies).toEqual([{ kind: 'composition_result', binding }])
  })

  const logical = () => ({ ...status().request, request_context: { composition_run_id: runId, source_task_id: 'task-A' },
    continuation: { kind: 'observed', observation: { composition_run_id: runId, source_task_id: 'task-A',
      owner: { request_id: 'current-logical-owner', generation: 2 }, journal_version: 'a'.repeat(64), observed_at: 3,
      resolution: { owner: { request_id: 'current-logical-owner', generation: 2 }, decision: 'cancelled',
        requested_by: 'operator', reason: 'original resolution', resolved_at: 3,
        expected_version: 'b'.repeat(64), marker_version: 'c'.repeat(64) } } } })

  it('binds logical run/Task/resolution while keeping a newer logical owner independent of the physical request', async () => {
    const request = logical()
    const value = await lookup(request)
    expect(value.status === 'observed' && value.request.continuation).toEqual(request.continuation)
    expect(request.continuation.observation.owner.request_id).not.toBe(identity.request_id)
  })

  it.each(['run', 'task', 'resolution_owner', 'resolution_generation', 'generation', 'version', 'decision', 'context'])('rejects an unbound logical %s', async mismatch => {
    const request = logical()
    const observation = request.continuation.observation
    if (mismatch === 'run') observation.composition_run_id = '019ffc2b-0a41-7ba2-bf58-598e0e7f711c'
    if (mismatch === 'task') observation.source_task_id = 'another-task'
    if (mismatch === 'resolution_owner') observation.resolution.owner.request_id = 'another-owner'
    if (mismatch === 'resolution_generation') observation.resolution.owner.generation = 1
    if (mismatch === 'generation') observation.owner.generation = 0
    if (mismatch === 'version') observation.journal_version = 'not-a-version'
    if (mismatch === 'decision') observation.resolution.decision = 'guessed'
    if (mismatch === 'context') request.request_context.composition_run_id = 'another-source'
    await expect(lookup(request)).rejects.toThrow()
  })

  it('keeps an unavailable logical continuation independent of a valid physical result', async () => {
    const value = await lookup({ ...status().request, continuation: { kind: 'unavailable', detail: 'journal unavailable' } })
    expect(value.status === 'observed' && value.nested.kind).toBe('observed')
  })

  it('preserves the decoded new source on a later physical validation failure', async () => {
    const request: Record<string, unknown> = { ...status().request, request_context: { replaced: true } }
    delete request.continuation
    const source = asyncRequestSourceKey({ status: 'observed', request, nested: { kind: 'absent' } })
    await expect(lookup(request)).rejects.toMatchObject({ source })
  })
})
