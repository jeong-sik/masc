import { afterEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from './core'
import { fetchToolBlobBytes } from './tool-blob'

afterEach(() => {
  clearStoredToken()
  vi.unstubAllGlobals()
})

describe('fetchToolBlobBytes', () => {
  it('sends the operator token and preserves binary bytes', async () => {
    setStoredToken('admin-token', { source: 'manual' })
    const buffer = new ArrayBuffer(4)
    const bytes = new Uint8Array(buffer)
    bytes.set([0, 255, 128, 42])
    const fetchMock = vi.fn().mockResolvedValue(new Response(buffer, { status: 200 }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchToolBlobBytes('a'.repeat(64))

    expect(new Uint8Array(result)).toEqual(bytes)
    expect(fetchMock).toHaveBeenCalledWith(
      `/api/v1/artifact-bytes/${'a'.repeat(64)}`,
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: 'Bearer admin-token' }),
      }),
    )
  })

  it('surfaces an authorization failure', async () => {
    setStoredToken('worker-token', { source: 'manual' })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('', { status: 403 })))
    await expect(fetchToolBlobBytes('a'.repeat(64))).rejects.toMatchObject({ status: 403 })
  })
})
