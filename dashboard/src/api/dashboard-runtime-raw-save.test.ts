import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from './core'
import { RuntimeTomlRevisionConflict, saveRuntimeTomlConfig } from './dashboard-runtime'

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

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

describe('raw runtime.toml revision-checked write', () => {
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

  it('keeps a network failure indeterminate instead of inventing a current revision', async () => {
    const failure = new TypeError('connection lost')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(failure))
    await expect(saveRuntimeTomlConfig('# draft\n', revision, saveOptions)).rejects.toBe(failure)
  })
})
