import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  authSession,
  bootstrapAuthSession,
  bumpSessionEpoch,
  currentSessionEpoch,
  registerWorkspaceTargets,
  resetAuthStateForTests,
  selectWorkspace,
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
      if (url === '/auth/session') {
        return jsonResponse({
          user_id: 'acct-1',
          expires_at_ms: 1_800_000_000_000,
          csrf_token: `csrf-r${csrfRev++}`,
        })
      }
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({
          principal: { kind: 'human', id: 'acct-1' },
          role: 'admin',
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

  it('does NOT refresh CSRF or retry on ordinary RBAC 403 forbidden or unchanged CSRF token', async () => {
    let sessionFetches = 0
    let rbacPosts = 0
    let sameCsrfPosts = 0

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') {
        sessionFetches += 1
        return jsonResponse({ user_id: 'acct-worker', expires_at_ms: 1, csrf_token: 'csrf-fixed' })
      }
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({ principal: { kind: 'human', id: 'acct-worker' }, role: 'worker' })
      }
      if (url === '/api/v1/infra/admin-only') {
        rbacPosts += 1
        return jsonResponse({ error: { code: 'not_an_admin', message: 'Forbidden' } }, 403)
      }
      if (url === '/api/v1/operator/same-csrf') {
        sameCsrfPosts += 1
        return jsonResponse({ error: { code: 'csrf_invalid', message: 'CSRF mismatch' } }, 403)
      }
      throw new Error(`unexpected url: ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(sessionFetches).toBe(1)

    // Ordinary RBAC 403 forbidden must NOT trigger CSRF refresh or retry
    const rbacRes = await apiMutate('POST', '/api/v1/infra/admin-only', {}, {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(rbacRes.ok).toBe(false)
    if (!rbacRes.ok) expect(rbacRes.error.kind).toBe('forbidden')
    expect(rbacPosts).toBe(1)
    expect(sessionFetches).toBe(1)

    // CSRF rejection where refresh returns identical token must NOT blindly retry
    const csrfRes = await apiMutate('POST', '/api/v1/operator/same-csrf', {}, {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(csrfRes.ok).toBe(false)
    if (!csrfRes.ok) expect(csrfRes.error.kind).toBe('csrf_rejected')
    expect(sameCsrfPosts).toBe(1)
    expect(sessionFetches).toBe(2)
  })

  it.each(['malformed response', 'network failure'])(
    'returns the original CSRF rejection after a refresh %s',
    async (failure) => {
      let sessionFetches = 0
      let postAttempts = 0
      const fetchMock: typeof fetch = async (input) => {
        const url = String(input)
        if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
        if (url === '/auth/session') {
          sessionFetches += 1
          if (sessionFetches === 1) return jsonResponse({ user_id: 'acct-1', csrf_token: 'csrf-1' })
          if (failure === 'network failure') throw new TypeError('Failed to fetch')
          return new Response('{ invalid json')
        }
        if (url === '/api/v1/auth/whoami') {
          return jsonResponse({ principal: { kind: 'human', id: 'acct-1' }, role: 'worker' })
        }
        if (url === '/api/v1/operator/action') {
          postAttempts += 1
          return jsonResponse({ error: { code: 'csrf_invalid', message: 'CSRF expired' } }, 403)
        }
        throw new Error(`unexpected url: ${url}`)
      }

      await bootstrapAuthSession({ fetchImpl: fetchMock })
      const result = await apiMutate('POST', '/api/v1/operator/action', {}, { fetchImpl: fetchMock })
      expect(result).toMatchObject({ ok: false, error: { kind: 'csrf_rejected', status: 403 } })
      expect(sessionFetches).toBe(2)
      expect(postAttempts).toBe(1)
    },
  )

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
  it('preserves parsed JSON error body on ApiError for HTTP 500 recovery inspection', async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ recorded: true, state: 'wakeup_deferred', error: 'wakeup queued' }, 500),
    )

    const res = await apiMutate('POST', '/api/v1/keepers/ask-answer', { ask_id: 'a1' }, {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(res.ok).toBe(false)
    if (!res.ok) {
      expect(res.error.status).toBe(500)
      expect(res.error.body).toEqual({
        recorded: true,
        state: 'wakeup_deferred',
        error: 'wakeup queued',
      })
    }
  })

  it('triggers throttled whoami-only recheck on non-CSRF 403 and bumps sessionEpoch on demotion', async () => {
    let sessionFetches = 0
    let whoamiFetches = 0
    let serverRole: 'admin' | 'worker' = 'admin'

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') {
        sessionFetches += 1
        return jsonResponse({ user_id: 'acct-403', csrf_token: 'csrf-403' })
      }
      if (url === '/api/v1/auth/whoami') {
        whoamiFetches += 1
        return jsonResponse({ principal: { kind: 'human', id: 'acct-403' }, role: serverRole })
      }
      if (url === '/api/v1/dashboard/logs') {
        return jsonResponse({ error: { code: 'forbidden', message: 'Admin role required' } }, 403)
      }
      throw new Error(`unexpected url: ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(sessionFetches).toBe(1)
    expect(whoamiFetches).toBe(1)
    expect(authSession.value).toMatchObject({ kind: 'multi_account_signed_in', role: 'admin' })

    serverRole = 'worker'
    const epochBefore = currentSessionEpoch()
    const res1 = await apiGet('/api/v1/dashboard/logs', { fetchImpl: fetchMock as unknown as typeof fetch })
    expect(res1.ok).toBe(false)

    await vi.waitFor(() => {
      expect(authSession.value).toMatchObject({ kind: 'multi_account_signed_in', role: 'worker' })
    })
    expect(currentSessionEpoch()).toBe(epochBefore + 1)
    // Must never touch /auth/session on ordinary RBAC 403
    expect(sessionFetches).toBe(1)
    expect(whoamiFetches).toBe(2)

    // Subsequent 403 inside cooldown window is throttled
    await apiGet('/api/v1/dashboard/logs', { fetchImpl: fetchMock as unknown as typeof fetch })
    await new Promise((r) => setTimeout(r, 10))
    expect(whoamiFetches).toBe(2)
  })

  it('coalesces simultaneous GET requests while preserving independent caller AbortSignals', async () => {
    let resolveFetch!: (res: Response) => void
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      return new Promise<Response>((resolve, reject) => {
        resolveFetch = resolve
        init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
      })
    })

    const ac1 = new AbortController()
    const ac2 = new AbortController()
    const p1 = apiGet<{ ok: boolean }>('/api/v1/keepers/tool-approvals', {
      fetchImpl: fetchMock as unknown as typeof fetch,
      signal: ac1.signal,
    })
    const p2 = apiGet<{ ok: boolean }>('/api/v1/keepers/tool-approvals', {
      fetchImpl: fetchMock as unknown as typeof fetch,
      signal: ac2.signal,
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    ac1.abort()
    const r1 = await p1
    expect(r1.ok).toBe(false)
    if (!r1.ok) expect(r1.error.kind).toBe('aborted')

    resolveFetch(jsonResponse({ ok: true }))
    const r2 = await p2
    expect(r2.ok).toBe(true)
    if (r2.ok) expect(r2.value.ok).toBe(true)
  })

  it('reuses ETag-cached body on 304 Not Modified and clears cache after unsafe mutations', async () => {
    let seenIfNoneMatch: string | null = null
    let calls = 0
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const hdrs = (init?.headers ?? {}) as Record<string, string>
      if (init?.method === 'POST') {
        return jsonResponse({ ok: true })
      }
      calls += 1
      seenIfNoneMatch = hdrs['If-None-Match'] ?? null
      if (seenIfNoneMatch === 'W/"v1"') {
        return new Response(null, { status: 304 })
      }
      return new Response(JSON.stringify({ url, seq: calls }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', ETag: 'W/"v1"' },
      })
    })

    const first = await apiGet<{ seq: number }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(first.ok).toBe(true)
    if (first.ok) expect(first.value.seq).toBe(1)

    const second = await apiGet<{ seq: number }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(seenIfNoneMatch).toBe('W/"v1"')
    expect(second.ok).toBe(true)
    if (second.ok) expect(second.value.seq).toBe(1)

    await apiMutate('POST', '/api/v1/dashboard/goals/mutate', {}, {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    const third = await apiGet<{ seq: number }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(seenIfNoneMatch).toBeNull()
    expect(third.ok).toBe(true)
    if (third.ok) expect(third.value.seq).toBe(3)
  })

  it('does not coalesce post-mutation GET onto a pre-mutation flight or poison ETag cache', async () => {
    let resolvePre!: (res: Response) => void
    let getCalls = 0
    const seenIfNoneMatch: Array<string | null> = []
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'POST') {
        return Promise.resolve(jsonResponse({ ok: true }))
      }
      getCalls += 1
      const hdrs = (init?.headers ?? {}) as Record<string, string>
      seenIfNoneMatch.push(hdrs['If-None-Match'] ?? null)
      if (getCalls === 1) {
        return new Promise<Response>((resolve) => {
          resolvePre = resolve
        })
      }
      return Promise.resolve(new Response(JSON.stringify({ rev: getCalls }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', ETag: `W/"r${getCalls}"` },
      }))
    })

    const preGet = apiGet<{ rev: number }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(getCalls).toBe(1)

    // Unsafe mutation completes while preGet is still in flight
    const mutRes = await apiMutate('POST', '/api/v1/dashboard/goals/mutate', {}, {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(mutRes.ok).toBe(true)

    // Post-mutation GET must start a fresh flight (must NOT coalesce onto preGet)
    const postGet = await apiGet<{ rev: number }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(getCalls).toBe(2)
    expect(postGet.ok).toBe(true)
    if (postGet.ok) expect(postGet.value.rev).toBe(2)

    // Pre-mutation GET settles late with an old ETag — must NOT overwrite ETag cache
    resolvePre(new Response(JSON.stringify({ rev: 1 }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', ETag: 'W/"stale-r1"' },
    }))
    await preGet

    await apiGet<{ rev: number }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(seenIfNoneMatch[2]).toBe('W/"r2"')
  })

  it('synchronously aborts shared flight on last caller abort so immediate replacement GET starts fresh', async () => {
    let calls = 0
    const signals: Array<AbortSignal | null | undefined> = []
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      calls += 1
      signals.push(init?.signal)
      if (calls === 1) {
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
        })
      }
      return Promise.resolve(jsonResponse({ fresh: true }))
    })

    const ac = new AbortController()
    const p1 = apiGet<{ fresh: boolean }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
      signal: ac.signal,
    })
    // Abort and immediately issue replacement GET in the same synchronous turn (no await between)
    ac.abort()
    expect(signals[0]?.aborted).toBe(true)
    const p2 = apiGet<{ fresh: boolean }>('/api/v1/dashboard/planning', {
      fetchImpl: fetchMock as unknown as typeof fetch,
    })
    expect(calls).toBe(2)

    const [r1, r2] = await Promise.all([p1, p2])
    expect(r1.ok).toBe(false)
    if (!r1.ok) expect(r1.error.kind).toBe('aborted')
    expect(r2.ok).toBe(true)
    if (r2.ok) expect(r2.value.fresh).toBe(true)
  })

  it('does not consume literal /api/v1/dashboard/shell bootstrap handoff when workspace baseUrl prefixes the URL', async () => {
    const requested: string[] = []
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      requested.push(url)
      if (url === '/health') return jsonResponse({ account_mode: 'Single_user' })
      if (url === '/api/v1/dashboard/shell') return jsonResponse({ source: 'root-bootstrap' })
      if (url === '/ws/sub/api/v1/dashboard/shell') return jsonResponse({ source: 'sub-workspace' })
      return jsonResponse({}, 404)
    })

    try {
      await bootstrapAuthSession()
      // Registering targets with the already-active 'default' id having a baseUrl keeps the same epoch
      registerWorkspaceTargets([{ id: 'default', label: 'Sub', baseUrl: '/ws/sub' }])
      const res = await apiGet<{ source: string }>('/api/v1/dashboard/shell')
      expect(res.ok).toBe(true)
      if (res.ok) expect(res.value.source).toBe('sub-workspace')
      expect(requested).toContain('/ws/sub/api/v1/dashboard/shell')
      // Avoid unused warning on selectWorkspace import while verifying workspace switch path too
      expect(selectWorkspace('default')).toBe(false)
    } finally {
      fetchSpy.mockRestore()
    }
  })
})
