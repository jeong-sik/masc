import { afterEach, describe, expect, it, vi } from 'vitest'
import { createHash } from 'node:crypto'

const sha256 = (bytes: Uint8Array): Uint8Array => createHash('sha256').update(bytes).digest()
const bytesToHex = (bytes: Uint8Array): string => Buffer.from(bytes).toString('hex')
const fromByteArray = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64')
import { asyncRequestSourceKey, fetchAsyncRequestStatus, fetchOriginalToolResult } from './composition-observation'

const encoder = new TextEncoder()
const hash = (content: string | Uint8Array) => bytesToHex(sha256(typeof content === 'string' ? encoder.encode(content) : content))
const runId = '019ffc2b-0a41-7ba2-bf58-598e0e7f711b'
const reference = { identity: { source_id: 'workspace', package_id: 'child', name: 'child' }, content_revision: 'a'.repeat(64) }

function page(content: Uint8Array, offset: number, next: number, patch = {}) {
  return { keeper: 'observer', execution_id: 'exec-exact', state: 'page', source_id: 'c'.repeat(64),
    body_sha256: hash(content), recorded_bytes: content.byteLength, is_error: false,
    page: { ok: true, sha256: hash(content), offset, next_offset: next, total_bytes: content.byteLength,
      eof: next === content.byteLength, content: fromByteArray(content.slice(offset, next)), encoding: 'base64', ...patch } }
}
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

describe('exact original body transport', () => {
  it('joins byte pages across a multibyte UTF8 boundary before decoding and checking the digest', async () => {
    const body = encoder.encode('🙂 original result payload')
    const fetch = vi.fn().mockResolvedValueOnce(Response.json(page(body, 0, 1)))
      .mockResolvedValueOnce(Response.json(page(body, 1, body.byteLength)))
    vi.stubGlobal('fetch', fetch)
    const value = await fetchOriginalToolResult('observer', 'exec-exact')
    expect(value.state === 'body' && value.content).toBe(new TextDecoder().decode(body))
    expect(String(fetch.mock.calls[1]?.[0])).toContain('offset=1&source_id=')
    expect(String(fetch.mock.calls[0]?.[0])).not.toContain('tool_use_id')
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
    ok: true, result: { value: 'retained' }, continuation: { kind: 'not_composition' },
  } })
  it('looks up the exact submitter/id while binding the returned Keeper and original result', async () => {
    const fetch = vi.fn().mockResolvedValue(Response.json(status()))
    vi.stubGlobal('fetch', fetch)
    const value = await fetchAsyncRequestStatus(identity)
    expect(value.status).toBe('observed')
    expect(String(fetch.mock.calls[0]?.[0])).toBe('/api/v1/async-requests/status?submitted_by=operator&request_id=retained-request')
  })
  it('accepts the producer error status', async () => {
    const payload = status()
    payload.request.status = 'error'; payload.request.ok = false
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json(payload)))
    const value = await fetchAsyncRequestStatus(identity)
    expect(value.status === 'observed' && value.request.status).toBe('error')
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
      { completed_at: 2, dependencies: [dependency], worker_released: true, result: {} })
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
    expect(value.status).toBe('observed')
  })

  it('preserves the decoded new source on a later physical validation failure', async () => {
    const request: Record<string, unknown> = { ...status().request, request_context: { replaced: true } }
    delete request.continuation
    const source = asyncRequestSourceKey({ status: 'observed', request })
    await expect(lookup(request)).rejects.toMatchObject({ source })
  })
})
