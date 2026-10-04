import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from './core'
import { RuntimeTomlRevisionConflict, saveRuntimeTomlConfig, fetchRuntimeTomlConfig,
  patchRuntimeRouting, patchRuntimeExactSlot, patchRuntimeAssignment, type RuntimeTomlRequestOptions } from './dashboard-runtime'
import { ensureDevToken } from './dev-token'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => undefined) }))

const revision = 'a'.repeat(64)
const current = { source_path: '/synthetic/runtime.toml', source_text: '# other writer\n', source_revision: 'b'.repeat(64) }
const conflict = { error: 'runtime.toml changed', code: 'revision_conflict', current }

function reply(body: unknown, status = 409) {
  const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

describe('raw runtime.toml revision-checked write', () => {
  it.each([
    ['read', (options: RuntimeTomlRequestOptions) => fetchRuntimeTomlConfig(options)],
    ['raw save', (options: RuntimeTomlRequestOptions) => saveRuntimeTomlConfig('# draft', revision, options)],
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
    await expect(saveRuntimeTomlConfig('# draft\n', revision)).rejects.toMatchObject({
      name: 'RuntimeTomlRevisionConflict', current,
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [path, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(path).toBe('/api/v1/runtime/config/raw')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      source_text: '# draft\n', expected_source_revision: revision,
    })
  })

  it.each(['', 'not-a-revision', 'A'.repeat(64)])('rejects invalid write revision %s before POST', async invalid => {
    const fetchMock = reply(conflict)
    await expect(saveRuntimeTomlConfig('# draft\n', invalid)).rejects.toThrow('저장 기준 revision')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it.each([
    { ...conflict, current: { ...current, source_revision: 'latest' } },
    { ...conflict, current: { ...current, source_text: null } },
    { ...conflict, current: { ...current, source_path: '' } },
    { ...conflict, code: 'io_error' },
  ])('does not authorize a malformed or unrelated failure as a usable conflict', async body => {
    reply(body)
    const error = await saveRuntimeTomlConfig('# draft\n', revision).catch(error => error)
    expect(error).toBeInstanceOf(ApiRequestError)
    expect(error).not.toBeInstanceOf(RuntimeTomlRevisionConflict)
  })

  it('keeps a network failure indeterminate instead of inventing a current revision', async () => {
    const failure = new TypeError('connection lost')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(failure))
    await expect(saveRuntimeTomlConfig('# draft\n', revision)).rejects.toBe(failure)
  })
})
