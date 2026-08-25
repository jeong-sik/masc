import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchKeeperGithubIdentity,
  streamKeeperGithubLogin,
  type KeeperGithubIdentityObservation,
  type KeeperGithubLoginEvent,
} from './dashboard-keeper-github'

// The dev-token bootstrap owns its own fetch traffic. Stubbing it out pins
// every `fetch` call observed below to the github-identity surface itself.
vi.mock('./dev-token', () => ({
  ensureDevToken: vi.fn(async () => undefined),
}))

afterEach(() => {
  vi.unstubAllGlobals()
})

const observation: KeeperGithubIdentityObservation = {
  ok: true,
  keeper: 'sangsu',
  hostname: 'github.com',
  config_dir: '/tmp/base/.masc/keepers/sangsu/github-cli',
  projected_token_env_names: ['GH_TOKEN'],
  stored: { authenticated: true, login: 'masc-sangsu-bot', error: null },
  effective: { authenticated: false, login: null, error: 'HTTP 401' },
  effective_probe_scope: 'host_process_credential_only',
  checked_at_unix: 1786000000,
}

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('fetchKeeperGithubIdentity', () => {
  it('encodes the keeper and hostname into the request path', async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL) => jsonResponse(observation))
    vi.stubGlobal('fetch', fetchMock)

    const decoded = await fetchKeeperGithubIdentity('keeper one', 'github.com')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const requested = fetchMock.mock.calls[0]?.[0]
    expect(requested).toBe(
      '/api/v1/keepers/keeper%20one/github-identity?hostname=github.com',
    )
    expect(decoded.stored.login).toBe('masc-sangsu-bot')
    expect(decoded.effective.authenticated).toBe(false)
    expect(decoded.projected_token_env_names).toEqual(['GH_TOKEN'])
  })

  it('rejects when the server refuses the observation', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ error: 'unknown keeper' }, 404)),
    )
    await expect(fetchKeeperGithubIdentity('ghost')).rejects.toThrow()
  })
})

function sseBody(chunks: readonly string[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder()
  return new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk))
      controller.close()
    },
  })
}

function stubStreamFetch(chunks: readonly string[]) {
  const fetchMock = vi.fn(async () =>
    ({ ok: true, body: sseBody(chunks) }) as unknown as Response,
  )
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

async function collectLoginEvents(
  chunks: readonly string[],
): Promise<KeeperGithubLoginEvent[]> {
  stubStreamFetch(chunks)
  const events: KeeperGithubLoginEvent[] = []
  await streamKeeperGithubLogin(
    'sangsu',
    'github.com',
    event => events.push(event),
    new AbortController().signal,
  )
  return events
}

describe('streamKeeperGithubLogin', () => {
  it('decodes output, complete, and error frames in order', async () => {
    const events = await collectLoginEvents([
      'event: output\ndata: {"stream":"stdout","text":"code: ABCD-1234"}\n\n',
      'event: output\ndata: {"stream":"stderr","text":"open https://github.com/login/device"}\n\n',
      `event: complete\ndata: ${JSON.stringify({ observation })}\n\n`,
    ])

    expect(events).toEqual([
      { event: 'output', stream: 'stdout', text: 'code: ABCD-1234' },
      { event: 'output', stream: 'stderr', text: 'open https://github.com/login/device' },
      { event: 'complete', observation },
    ])
  })

  it('reassembles a frame that arrives split across chunks', async () => {
    const events = await collectLoginEvents([
      'event: output\ndata: {"stream":"stdo',
      'ut","text":"first half+second half"}\n\n',
    ])
    expect(events).toEqual([
      { event: 'output', stream: 'stdout', text: 'first half+second half' },
    ])
  })

  it('accepts CRLF framing from the wire', async () => {
    const events = await collectLoginEvents([
      'event: error\r\ndata: {"message":"gh exited with 1"}\r\n\r\n',
    ])
    expect(events).toEqual([{ event: 'error', message: 'gh exited with 1' }])
  })

  it('surfaces the response body when the login request is refused', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        ({ ok: false, status: 409, text: async () => 'login already running' }) as unknown as Response,
      ),
    )
    await expect(
      streamKeeperGithubLogin('sangsu', 'github.com', () => {}, new AbortController().signal),
    ).rejects.toThrow('login already running')
  })

  it('rejects a response without a stream body', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({ ok: true, body: null }) as unknown as Response),
    )
    await expect(
      streamKeeperGithubLogin('sangsu', 'github.com', () => {}, new AbortController().signal),
    ).rejects.toThrow('GitHub login stream is unavailable')
  })
})
