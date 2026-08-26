import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchIdentityProviders,
  isConnectable,
  startIdentityLogin,
  type IdentityProvider,
} from './dashboard-keeper-identity'

// The dev-token bootstrap owns its own fetch traffic. Stubbing it out pins
// every `fetch` call observed below to the identity surface itself.
vi.mock('./dev-token', () => ({
  ensureDevToken: vi.fn(async () => undefined),
}))

afterEach(() => {
  vi.unstubAllGlobals()
})

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('fetchIdentityProviders', () => {
  it('keeps a declaration the server could not read', async () => {
    // Dropping it would show a shorter list and no reason the provider the
    // operator came for is missing.
    const providers: IdentityProvider[] = [
      { id: 'atlassian', label: 'Atlassian' },
      { id: 'jira', problem: 'id does not match the file name' },
    ]
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ providers })),
    )
    const found = await fetchIdentityProviders()
    expect(found).toHaveLength(2)
    expect(found.filter(isConnectable).map(p => p.id)).toEqual(['atlassian'])
  })

  it('reads an empty answer as nothing declared, not as a failure', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({})),
    )
    await expect(fetchIdentityProviders()).resolves.toEqual([])
  })
})

describe('startIdentityLogin', () => {
  it('names the keeper in the path and the provider in the body', async () => {
    const fetchMock = vi.fn(async (_path: string, _init: RequestInit) =>
      jsonResponse({
        keeper: 'sang su',
        provider: 'atlassian',
        provider_label: 'Atlassian',
        authorize_url: 'https://auth.atlassian.com/authorize?x=1',
        state: 'abc',
        registered_now: true,
        expires_at: 1786000600,
      }),
    )
    vi.stubGlobal('fetch', fetchMock)
    const started = await startIdentityLogin('sang su', 'atlassian')
    expect(started.authorize_url).toBe(
      'https://auth.atlassian.com/authorize?x=1',
    )
    const call = fetchMock.mock.calls[0]
    expect(call).toBeDefined()
    const [path, init] = call!
    expect(path).toBe('/api/v1/keepers/sang%20su/oauth-login')
    expect(JSON.parse(String(init.body))).toEqual({ provider: 'atlassian' })
  })
})
