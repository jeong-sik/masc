import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchAttachedProviders,
  isAttachable,
  refreshIdentityTools,
  startIdentityLogin,
  type AttachedProvider,
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

describe('fetchAttachedProviders', () => {
  it('keeps a declaration the server could not read', async () => {
    // Dropping it would show a shorter list and no reason the provider the
    // operator came for is missing.
    const providers: AttachedProvider[] = [
      {
        provider: 'atlassian',
        provider_label: 'Atlassian',
        attached: true,
        tools: ['getJiraIssue'],
      },
      { provider: 'jira', problem: 'id does not match the file name' },
    ]
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ providers })),
    )
    const found = await fetchAttachedProviders('sangsu')
    expect(found).toHaveLength(2)
    expect(found.filter(isAttachable).map(p => p.provider)).toEqual(['atlassian'])
  })

  it('keeps attached-with-no-tools apart from never attached', async () => {
    // Reading one as the other would tell an operator to consent again for
    // no reason.
    const providers: AttachedProvider[] = [
      { provider: 'a', provider_label: 'A', attached: true, tools: [] },
      { provider: 'b', provider_label: 'B', attached: false },
    ]
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ providers })),
    )
    const found = (await fetchAttachedProviders('sangsu')).filter(isAttachable)
    expect(found[0]!.attached).toBe(true)
    expect(found[0]!.tools).toEqual([])
    expect(found[1]!.attached).toBe(false)
    expect(found[1]!.tools).toBeUndefined()
  })

  it('names the keeper in the query', async () => {
    const fetchMock = vi.fn(async (_path: string) => jsonResponse({ providers: [] }))
    vi.stubGlobal('fetch', fetchMock)
    await fetchAttachedProviders('sang su')
    const call = fetchMock.mock.calls[0]
    expect(call).toBeDefined()
    expect(call![0]).toBe(
      '/api/v1/keepers/oauth/attached-tools?keeper=sang%20su',
    )
  })

  it('reads an empty answer as nothing declared, not as a failure', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({})),
    )
    await expect(fetchAttachedProviders('sangsu')).resolves.toEqual([])
  })
})

describe('refreshIdentityTools', () => {
  it('names the keeper in the path and the provider in the body', async () => {
    const fetchMock = vi.fn(async (_path: string, _init: RequestInit) =>
      jsonResponse({ keeper: 'sangsu', provider: 'atlassian', tools: [] }),
    )
    vi.stubGlobal('fetch', fetchMock)
    await refreshIdentityTools('sangsu', 'atlassian')
    const call = fetchMock.mock.calls[0]
    expect(call).toBeDefined()
    const [path, init] = call!
    expect(path).toBe('/api/v1/keepers/sangsu/identity-refresh')
    expect(JSON.parse(String(init.body))).toEqual({ provider: 'atlassian' })
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
