import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  bootstrapAuthSession,
  bumpSessionEpoch,
  resetAuthStateForTests,
  setSingleUserToken,
} from './auth'
import {
  apiGet,
  apiGetV2,
  apiMutate,
  unwrapOkData,
  unwrapV2Envelope,
} from './transport'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('core/transport', () => {
  beforeEach(() => {
    resetAuthStateForTests()
  })

  afterEach(() => {
    resetAuthStateForTests()
  })

  it('sends same-origin cookies + x-masc-csrf-token (zero Bearer) in multi_account mode and retries once on 403 CSRF', async () => {
    let csrfRev = 1
    let postAttempt = 0
    const seenAuthHeaders: (string | undefined)[] = []
    const seenCsrfHeaders: (string | undefined)[] = []

    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/api/v1/auth/session') {
        return jsonResponse({
          authenticated: true,
          account_id: 'acct-1',
          role: 'admin',
          csrf_token: `csrf-r${csrfRev++}`,
        })
      }
      if (url === '/api/v1/operator/action') {
        expect(init?.credentials).toBe('same-origin')
        const hdrs = (init?.headers ?? {}) as Record<string, string>
        seenAuthHeaders.push(hdrs.Authorization)
        seenCsrfHeaders.push(hdrs['x-masc-csrf-token'])
        postAttempt += 1
        if (postAttempt === 1) {
          return jsonResponse({ error: { code: 'csrf_invalid', message: 'CSRF expired' } }, 403)
        }
        return jsonResponse({ ok: true, applied: true })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    const res = await apiMutate<{ ok: boolean; applied: boolean }>(
      'POST',
      '/api/v1/operator/action',
      { action: 'pause' },
      { fetchImpl: fetchMock as unknown as typeof fetch },
    )

    expect(res.ok).toBe(true)
    if (res.ok) expect(res.value.applied).toBe(true)
    expect(seenAuthHeaders).toEqual([undefined, undefined])
    expect(seenCsrfHeaders).toEqual(['csrf-r1', 'csrf-r2'])
  })

  it('sends Authorization: Bearer in single_user mode when token is set', async () => {
    setSingleUserToken('single-val-1')
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      const hdrs = (init?.headers ?? {}) as Record<string, string>
      expect(hdrs.Authorization).toBe('Bearer single-val-1')
      return jsonResponse({ items: [1, 2, 3] })
    })

    const res = await apiGet<{ items: number[] }>('/api/v1/dashboard/shell', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(res.ok).toBe(true)
    if (res.ok) expect(res.value.items).toEqual([1, 2, 3])
  })

  it('drops stale in-flight responses when sessionEpoch advances (epoch fence)', async () => {
    let resolveFetch!: (res: Response) => void
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      return new Promise<Response>((resolve, reject) => {
        resolveFetch = resolve
        init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
      })
    })

    const pending = apiGet<{ stale: boolean }>('/api/v1/dashboard/keepers', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })

    // Account or workspace switches while request is in flight
    bumpSessionEpoch()
    resolveFetch(jsonResponse({ stale: true }))

    const res = await pending
    expect(res.ok).toBe(false)
    if (!res.ok) {
      expect(res.error.kind).toBe('epoch_stale')
    }
  })

  it('unwraps V2 and { ok, data } wire envelopes accurately', async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        schema_version: 2,
        instance_id: 'inst-1',
        generated_at_unix: 1_700_000_000,
        data: { count: 42 },
      }),
    )

    const v2Res = await apiGetV2<{ count: number }>('/api/v1/dashboard/execution', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(v2Res.ok).toBe(true)
    if (v2Res.ok) expect(v2Res.value.count).toBe(42)

    const v2Err = unwrapV2Envelope({
      error: { code: 'conflict_cas', message: 'revision mismatch', field: 'revision' },
    })
    expect(v2Err.ok).toBe(false)
    if (!v2Err.ok) {
      expect(v2Err.error.kind).toBe('conflict_cas')
      expect(v2Err.error.field).toBe('revision')
    }

    const okRes = unwrapOkData<{ name: string }>({ ok: true, data: { name: 'sangsu' } })
    expect(okRes.ok).toBe(true)
    const notOk = unwrapOkData({ ok: false, error: 'denied', code: 'forbidden' })
    expect(notOk.ok).toBe(false)
  })
})
