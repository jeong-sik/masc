import { afterEach, describe, expect, it, vi } from 'vitest'

describe('keeper lifecycle control boundary', () => {
  afterEach(() => {
    vi.resetModules()
    vi.doUnmock('./core')
    vi.unstubAllGlobals()
  })

  it('does not synthesize a client deadline for boot actions', async () => {
    const fetchControlPlane = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )

    vi.doMock('./core', async (importOriginal) => {
      const actual = await importOriginal<typeof import('./core')>()
      return {
        ...actual,
        fetchControlPlane,
        currentDashboardActor: vi.fn(() => 'dashboard'),
        runOperatorAction: vi.fn(),
      }
    })

    const { bootKeeper } = await import('./keeper')

    const controller = new AbortController()
    await expect(bootKeeper('alpha', { signal: controller.signal })).resolves.toMatchObject({ ok: true })
    expect(fetchControlPlane).toHaveBeenCalledExactlyOnceWith(
      '/api/v1/keepers/alpha/boot',
      expect.objectContaining({ method: 'POST', signal: controller.signal }),
    )
  })

  it('propagates an explicit caller cancellation without reporting lifecycle failure', async () => {
    const fetchMock = vi.fn((_path: string, init?: RequestInit) => (
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => {
          reject(new DOMException('operator cancelled', 'AbortError'))
        }, { once: true })
      })
    ))
    vi.stubGlobal('fetch', fetchMock)

    const { bootKeeper } = await import('./keeper')
    const controller = new AbortController()
    const request = bootKeeper('alpha', { signal: controller.signal })
    controller.abort()

    await expect(request).rejects.toMatchObject({ name: 'AbortError' })
  })
})
