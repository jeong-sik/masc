import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from './core'
import { RuntimeTomlRevisionConflict, saveRuntimeTomlConfig } from './dashboard-runtime'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => undefined) }))

const revision = 'a'.repeat(64)
const base = { sourcePath: '/synthetic/runtime.toml', sourceRevision: revision }
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
    await expect(saveRuntimeTomlConfig('# draft\n', base)).rejects.toMatchObject({
      name: 'RuntimeTomlRevisionConflict', current,
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [path, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(path).toBe('/api/v1/runtime/config/raw')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      source_text: '# draft\n', expected_source_path: base.sourcePath, expected_source_revision: revision,
    })
  })

  it.each(['', 'not-a-revision', 'A'.repeat(64)])('rejects invalid write revision %s before POST', async invalid => {
    const fetchMock = reply(conflict)
    await expect(saveRuntimeTomlConfig('# draft\n', { ...base, sourceRevision: invalid }))
      .rejects.toThrow('저장 기준 revision')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('rejects a write base without the path its text was read from before POST', async () => {
    const fetchMock = reply(conflict)
    await expect(saveRuntimeTomlConfig('# draft\n', { ...base, sourcePath: '' }))
      .rejects.toThrow('저장 기준 경로')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it.each([
    { ...conflict, current: { ...current, source_revision: 'latest' } },
    { ...conflict, current: { ...current, source_text: null } },
    { ...conflict, current: { ...current, source_path: '' } },
    { ...conflict, code: 'io_error' },
  ])('does not authorize a malformed or unrelated failure as a usable conflict', async body => {
    reply(body)
    const error = await saveRuntimeTomlConfig('# draft\n', base).catch(error => error)
    expect(error).toBeInstanceOf(ApiRequestError)
    expect(error).not.toBeInstanceOf(RuntimeTomlRevisionConflict)
  })

  it('keeps a network failure indeterminate instead of inventing a current revision', async () => {
    const failure = new TypeError('connection lost')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(failure))
    await expect(saveRuntimeTomlConfig('# draft\n', base)).rejects.toBe(failure)
  })
})
