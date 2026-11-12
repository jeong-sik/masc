import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

interface PendingRequest {
  readonly path: string
  readonly signal: AbortSignal | undefined
  readonly authorization: string | null
  readonly respond: (body: unknown, status?: number) => void
}

let requests: PendingRequest[]
let store: typeof import('./store')
let core: typeof import('./api/core')
let confirmWorkspace: () => void
const disposers: Array<() => void> = []

const flush = async () => {
  for (let index = 0; index < 16; index += 1) await Promise.resolve()
}

function shell(keepers: number) {
  return {
    generated_at: '2026-11-10T00:00:00Z',
    status: { project: 'fixture', workspace_root: '/fixture/runtime-consumer' },
    counts: { agents: 1, tasks: 2, keepers, total_runtimes: keepers + 1 },
    auth: { enabled: false, require_token: false, token_present: false, token_valid: false },
  }
}

async function request(number: number): Promise<PendingRequest> {
  await vi.waitFor(() => expect(requests).toHaveLength(number))
  return requests[number - 1]!
}

beforeEach(async () => {
  vi.resetModules()
  requests = []
  vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>(resolve => {
      requests.push({
        path: String(input), signal: init?.signal ?? undefined,
        authorization: new Headers(init?.headers).get('authorization'),
        respond: (body, status = 200) => resolve(new Response(JSON.stringify(body), {
          status, headers: { 'content-type': 'application/json' },
        })),
      })
    })))
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  core = await import('./api/core')
  core.setStoredToken('shell-observation-a', { source: 'manual' })
  store = await import('./store')
  const { confirmRuntimeTestWorkspace: confirm, RUNTIME_TEST_OBSERVER_INSTANCE } = await import('./lib/runtime-workspace.test-fixture')
  confirmWorkspace = () => {
    confirm()
    expect(store.executionWorkspaceAuthority.peek()).toEqual({
      epoch: expect.any(String), workspaceRoot: '/fixture/runtime-consumer',
      connectionGeneration: expect.any(Number),
      observerInstanceId: RUNTIME_TEST_OBSERVER_INSTANCE,
    })
  }
})

afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.resetModules()
  sessionStorage.clear()
  localStorage.clear()
})

describe('shared Shell observation through the actual HTTP reader', () => {
  it('lets one observer leave while a remaining full reader receives the body', async () => {
    confirmWorkspace()
    const controller = new AbortController()
    const observation = store.readShell({ force: true, signal: controller.signal })
    const active = await request(1)
    expect(active.path).toBe('/api/v1/dashboard/shell')
    expect(active.authorization).toBe('Bearer shell-observation-a')
    const manual = store.refreshShell()
    controller.abort()
    await expect(observation).resolves.toEqual({ kind: 'cancelled' })
    expect(active.signal?.aborted).toBe(false)
    active.respond(shell(7))
    await expect(manual).resolves.toBe(true)
    expect(store.shellCounts.peek()?.keepers).toBe(7)
  })

  it('cancels the last waiter HTTP and starts its replacement before the old body returns', async () => {
    confirmWorkspace()
    const controller = new AbortController()
    const retired = store.readShell({ force: true, signal: controller.signal })
    const original = await request(1)
    controller.abort()
    await expect(retired).resolves.toEqual({ kind: 'cancelled' })
    expect(original.signal?.aborted).toBe(true)
    const replacement = store.readShell({ force: true })
    const current = await request(2)
    current.respond(shell(22))
    await expect(replacement).resolves.toEqual({ kind: 'ready' })
    original.respond(shell(11))
    await flush()
    expect(store.shellCounts.peek()?.keepers).toBe(22)
  })

  it('retires a request when the real accepted workspace object changes', async () => {
    confirmWorkspace()
    const retired = store.readShell({ force: true })
    const original = await request(1)
    confirmWorkspace()
    await expect(retired).resolves.toEqual({ kind: 'cancelled' })
    expect(original.signal?.aborted).toBe(true)
    const replacement = store.readShell({ force: true })
    const current = await request(2)
    current.respond(shell(32))
    await expect(replacement).resolves.toEqual({ kind: 'ready' })
    original.respond(shell(31))
    await flush()
    expect(store.shellCounts.peek()?.keepers).toBe(32)
  })

  it.each([401, 403])('preserves raw HTTP %i while the existing manual API still returns false', async status => {
    confirmWorkspace()
    const actor = await import('./lib/dashboard-session-actor')
    actor.setCanonicalDashboardActor('codex')
    const observation = store.readShell({ force: true })
    const first = await request(1)
    first.respond({ error: 'denied' }, status)
    const outcome = await observation
    expect(outcome.kind).toBe('failed')
    if (outcome.kind !== 'failed') throw new Error('expected the original read failure')
    expect(outcome.cause).toBeInstanceOf(core.ApiRequestError)
    expect((outcome.cause as InstanceType<typeof core.ApiRequestError>).status).toBe(status)
    expect(actor.currentCanonicalDashboardActor()).toBe('codex')
    const manual = store.refreshShell({ force: true })
    const second = await request(2)
    second.respond({ error: 'denied' }, status)
    await expect(manual).resolves.toBe(false)
    expect(actor.currentCanonicalDashboardActor()).toBe('codex')
  })

  it('completes boot with a new full read when accepted authority arrives before the light response', async () => {
    expect(store.executionWorkspaceAuthority.peek()).toBeNull()
    disposers.push(store.setupShellObservation())
    const bootController = new AbortController()
    const boot = store.refreshShell({ light: true, signal: bootController.signal })
    const original = await request(1)
    expect(original.path).toBe('/api/v1/dashboard/shell?light=true')
    confirmWorkspace()
    await expect(boot).resolves.toBe(false)
    expect(original.signal?.aborted).toBe(true)
    const accepted = await request(2)
    expect(accepted.path).toBe('/api/v1/dashboard/shell')
    accepted.respond(shell(42))
    await vi.waitFor(() => expect(store.shellCounts.peek()?.keepers).toBe(42))
    original.respond(shell(41))
    await flush()
    expect(store.shellCounts.peek()?.keepers).toBe(42)
  })
})
