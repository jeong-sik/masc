import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from './core'
import { RuntimeTomlRevisionConflict, saveRuntimeTomlConfig, fetchRuntimeTomlConfig,
  patchRuntimeRouting, patchRuntimeExactSlot, patchRuntimeAssignment, type RuntimeTomlRequestOptions } from './dashboard-runtime'
import { ensureDevToken } from './dev-token'
import { committedRuntimeTomlConfigFixture } from '../lib/runtime-config-receipt.test-fixture'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => undefined) }))

const revision = 'a'.repeat(64)
const saveOptions = { expectedSourcePath: '/synthetic/runtime.toml' }
const current = { source_path: '/synthetic/runtime.toml', source_text: '# other writer\n', source_revision: 'b'.repeat(64) }
const conflict = { error: 'runtime.toml changed', code: 'revision_conflict', current }

function reply(body: unknown, status = 409) {
  const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

function committedResponse(durability: 'durable' | 'unconfirmed' = 'durable') {
  const value = committedRuntimeTomlConfigFixture({
    ok: true, path: saveOptions.expectedSourcePath, file_name: 'runtime.toml', source_text: '# saved',
    provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint',
      semantics: 'http_provider', credential_policy: 'optional', requires_non_interactive: false,
      provider_fields: [], required_provider_fields: [] }],
  }, { durability, skills: {
    state: 'published', input_source_revision: revision, snapshot_revision: 'snapshot',
    catalog_revision: 'catalog', config_state: 'configured',
  } })
  return { ...value, source_revision: revision, commit: { ...value.commit, source_revision: revision } }
}

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

describe('raw runtime.toml revision-checked write', () => {
  it.each(['durable', 'unconfirmed'] as const)('retains %s commit observation without repeating the POST', async durability => {
    const committed = committedResponse(durability)
    const fetchMock = reply(committed, 200)
    const result = await saveRuntimeTomlConfig('# draft', revision, saveOptions)
    expect(result.commit).toEqual(committed.commit)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it.each([
    { durability: 'unconfirmed', durability_detail: null },
    { durability: 'durable', durability_detail: 'contradictory sync warning' },
    { durability: 'future', durability_detail: null },
    { durability: 'unconfirmed', durability_detail: '' },
    { warnings: [null] },
  ])('keeps an unreadable commit indeterminate without repeating the write', async invalid => {
    const committed = committedResponse()
    const fetchMock = reply({ ...committed, commit: { ...committed.commit, ...invalid } }, 200)
    const outcome = await saveRuntimeTomlConfig('# draft', revision, saveOptions).catch(error => error)
    expect(outcome).toBeInstanceOf(Error)
    expect(outcome).not.toMatchObject({ name: 'RuntimeTomlSaveRejected' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it.each([401, 403])('classifies structured raw-save authorization status %s as pre-handler refusal', async status => {
    const fetchMock = reply({ error: 'authorization rejected', auth_error_code: status === 401 ? 'token_expired' : 'insufficient_role' }, status)
    await expect(saveRuntimeTomlConfig('# draft', revision, saveOptions)).rejects.toMatchObject({ name: 'RuntimeTomlSaveRejected' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
  it.each([401, 403])('does not invent a typed auth refusal from unstructured status %s', async status => {
    reply({ error: 'unrecognized gateway refusal' }, status)
    await expect(saveRuntimeTomlConfig('# draft', revision, saveOptions)).rejects.toBeInstanceOf(ApiRequestError)
  })
  it.each([401, 403])('keeps ambiguous authorization status %s unknown', async status => {
    reply({ error: 'authorization-like failure after application', config_applied: true }, status)
    await expect(saveRuntimeTomlConfig('# draft', revision, saveOptions)).rejects.toBeInstanceOf(ApiRequestError)
  })

  it.each([
    ['read', (options: RuntimeTomlRequestOptions) => fetchRuntimeTomlConfig(options)],
    ['raw save', (options: RuntimeTomlRequestOptions) => saveRuntimeTomlConfig('# draft', revision, { ...options, ...saveOptions })],
    ['routing', (options: RuntimeTomlRequestOptions) => patchRuntimeRouting('default', 'fixture.model', options)],
    ['exact slot', (options: RuntimeTomlRequestOptions) => patchRuntimeExactSlot('judge', 'append', 'fixture.model', undefined, options)],
    ['assignment', (options: RuntimeTomlRequestOptions) => patchRuntimeAssignment('keeper', 'fixture.model', {
      state: 'runtime_config_present', source_revision: revision, assignment: { state: 'missing' },
    }, options)],
  ] as const)('refuses %s dispatch if the workspace changes while preparing authentication', async (_name, request) => {
    let release!: () => void
    vi.mocked(ensureDevToken).mockImplementationOnce(() => new Promise(resolve => { release = () => resolve(undefined) }))
    const fetchMock = reply(conflict)
    let current = true
    const pending = request({ beforeDispatch: () => { if (!current) throw new Error('workspace changed') } })
    const rejected = expect(pending).rejects.toThrow('workspace changed')
    current = false; release()
    await rejected
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('sends the read revision with the draft and exposes the 409 current source without retrying', async () => {
    const fetchMock = reply(conflict)
    await expect(saveRuntimeTomlConfig('# draft\n', revision, saveOptions)).rejects.toMatchObject({
      name: 'RuntimeTomlRevisionConflict', current,
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [path, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(path).toBe('/api/v1/runtime/config/raw')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      source_text: '# draft\n', expected_source_revision: revision, expected_source_path: saveOptions.expectedSourcePath,
    })
  })

  it.each(['', '\0'])('rejects invalid write path before POST: %s', async path => {
    const fetchMock = reply(conflict)
    await expect(saveRuntimeTomlConfig('# draft', revision, { expectedSourcePath: path })).rejects.toThrow('저장 기준 path')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it.each(['', 'not-a-revision', 'A'.repeat(64)])('rejects invalid write revision %s before POST', async invalid => {
    const fetchMock = reply(conflict)
    await expect(saveRuntimeTomlConfig('# draft\n', invalid, saveOptions)).rejects.toThrow('저장 기준 revision')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it.each([
    { ...conflict, current: { ...current, source_revision: 'latest' } },
    { ...conflict, current: { ...current, source_text: null } },
    { ...conflict, current: { ...current, source_path: '' } },
    { ...conflict, code: 'io_error' },
  ])('does not authorize a malformed or unrelated failure as a usable conflict', async body => {
    reply(body)
    const error = await saveRuntimeTomlConfig('# draft\n', revision, saveOptions).catch(error => error)
    expect(error).toBeInstanceOf(ApiRequestError)
    expect(error).not.toBeInstanceOf(RuntimeTomlRevisionConflict)
  })

  it.each([
    { error: 'runtime config parse failed: invalid TOML' },
    { ok: false, error: 'runtime value rejected', validation: { valid: false, issues: [] } },
  ])('classifies the raw route structured 400 as a definite precommit refusal', async body => {
    const fetchMock = reply(body, 400)
    await expect(saveRuntimeTomlConfig('# draft', revision, saveOptions)).rejects.toMatchObject({ name: 'RuntimeTomlSaveRejected' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it.each([
    [500, { error: 'write failed' }], [422, { error: 'validation failed' }],
    [400, { error: { detail: 'unrecognized response' } }],
    [400, { error: 'applied but refresh failed', config_applied: true }],
    [400, { error: 'unknown outcome', config_application: { state: 'indeterminate' } }],
    [400, { error: 'read required', authoritative_reload_required: true }],
  ])('does not turn status %s or an ambiguous error into a definite rejection', async (status, body) => {
    reply(body, status as number)
    const error = await saveRuntimeTomlConfig('# draft', revision, saveOptions).catch(error => error)
    expect(error).toBeInstanceOf(ApiRequestError)
  })

  it('keeps a network failure indeterminate instead of inventing a current revision', async () => {
    const failure = new TypeError('connection lost')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(failure))
    await expect(saveRuntimeTomlConfig('# draft\n', revision, saveOptions)).rejects.toBe(failure)
  })
})
