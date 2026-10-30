import { webcrypto } from 'node:crypto'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchToolBlob } from './tool-blob'
import { fetchEditSnapshots, parseEditSnapshots } from './edit-snapshots'

vi.mock('./tool-blob', () => ({ fetchToolBlob: vi.fn() }))
afterEach(() => { vi.resetAllMocks(); vi.unstubAllGlobals() })

async function artifact(content: string) {
  const bytes = new TextEncoder().encode(content)
  const digest = await webcrypto.subtle.digest('SHA-256', bytes)
  const sha256 = Buffer.from(digest).toString('hex')
  return { content, bytes: bytes.length, sha256, mime: 'application/octet-stream' }
}

describe('recorded edit originals', () => {
  it('fetches and verifies both full files including indentation, CRLF and final newline', async () => {
    vi.stubGlobal('crypto', webcrypto)
    const before = await artifact('\told\r\nunchanged\r\n')
    const after = await artifact('\tnew\r\nunchanged\r\n')
    const refs = parseEditSnapshots({ status: 'stored', before: { _blob: before }, after: { _blob: after } })!
    vi.mocked(fetchToolBlob).mockImplementation(async hash => hash === before.sha256 ? before : after)
    if (refs.status !== 'stored') throw new Error('Expected stored snapshots')
    expect(await fetchEditSnapshots(refs)).toEqual({ before: before.content, after: after.content })
  })

  it('rejects altered content even when response metadata repeats the recorded digest', async () => {
    vi.stubGlobal('crypto', webcrypto)
    const original = await artifact('old')
    vi.mocked(fetchToolBlob).mockResolvedValue({ ...original, content: 'new' })
    await expect(fetchEditSnapshots({ before: original, after: original })).rejects.toThrow('바이트')
  })

  it('explains unavailable browser cryptography before requesting originals', async () => {
    vi.stubGlobal('crypto', {})
    const original = await artifact('old')
    await expect(fetchEditSnapshots({ before: original, after: original })).rejects.toThrow('HTTPS 또는 localhost')
    expect(fetchToolBlob).not.toHaveBeenCalled()
  })

  it('does not present incomplete or failed snapshot persistence as originals', () => {
    expect(parseEditSnapshots({ status: 'unavailable', detail: 'disk full' })).toEqual({ status: 'unavailable', detail: 'disk full' })
    expect(parseEditSnapshots({ status: 'unavailable' })).toBeNull()
    expect(parseEditSnapshots({ status: 'stored', before: { _blob: { sha256: 'a'.repeat(64), bytes: 3 } } })).toBeNull()
  })
})
