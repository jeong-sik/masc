import { afterEach, describe, expect, it, vi } from 'vitest'

describe('keeper lifecycle timeouts', () => {
  afterEach(() => {
    vi.resetModules()
    vi.doUnmock('./core')
  })

  it('uses a bounded lifecycle timeout for boot actions', async () => {
    const fetchWithTimeout = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )

    vi.doMock('./core', async (importOriginal) => {
      const actual = await importOriginal<typeof import('./core')>()
      return {
        ...actual,
        fetchWithTimeout,
        currentDashboardActor: vi.fn(() => 'dashboard'),
        runOperatorAction: vi.fn(),
      }
    })

    const { bootKeeper } = await import('./keeper')
    const { KEEPER_LIFECYCLE_TIMEOUT_MS } = await import('./core')

    await expect(bootKeeper('alpha')).resolves.toMatchObject({ ok: true })
    expect(fetchWithTimeout).toHaveBeenCalledWith(
      '/api/v1/keepers/alpha/boot',
      expect.objectContaining({ method: 'POST' }),
      KEEPER_LIFECYCLE_TIMEOUT_MS,
    )
  })
})
