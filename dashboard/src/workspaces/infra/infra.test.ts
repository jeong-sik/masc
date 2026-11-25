import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  OBSERVER_SSE_INSTANCE_HEADER,
  activeViewStreamKey,
  authSession,
  registerWorkspaceTargets,
  releaseAllViewStreams,
  resetAuthStateForTests,
  resetObserverStateForTests,
  resourceCache,
  selectWorkspace,
  setObserverSseInstanceId,
} from '../../core'
import { InfraWorkspace, type WorkspaceInspectPayload } from './index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function pendingSseResponse(): Response {
  const stream = new ReadableStream<Uint8Array>({
    start() { /* hold open until aborted */ },
  })
  return new Response(stream, {
    status: 200,
    headers: { 'Content-Type': 'text/event-stream' },
  })
}

async function flushUi(ms = 30): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms))
}

describe('workspaces/infra', () => {
  let container: HTMLDivElement
  let originalFetch: typeof globalThis.fetch

  beforeEach(() => {
    originalFetch = globalThis.fetch
    // Provide deterministic viewport height for @tanstack/virtual-core in happy-dom
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockImplementation(function (this: HTMLElement) {
      if (this.classList.contains('vlist') || this.classList.contains('dtable-scroll')) return 460
      return 0
    })
    vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockImplementation(function (this: HTMLElement) {
      if (this.classList.contains('vlist') || this.classList.contains('dtable-scroll')) return 1100
      return 0
    })
    resetAuthStateForTests()
    resetObserverStateForTests()
    releaseAllViewStreams()
    resourceCache.clearAll()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    releaseAllViewStreams()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('unwraps V2Envelope on Sandboxes, renders shim_parity, unobserved_reasons, null ssh_active_sessions as "미보고", and triggers probe POST', async () => {
    const calls: { url: string; method: string }[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const method = init?.method ?? 'GET'
      calls.push({ url, method })

      if (url === '/api/v1/infra/sandboxes' && method === 'GET') {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1_700_000_000,
          data: {
            probe_state: { kind: 'fresh', measured_at_unix: 1_700_000_000 },
            summary: {
              microvm_declared: 2,
              microvm_running: 2,
              microvm_sockets_present: 2,
              microvm_shim_mismatch: 0,
              ssh_pools: 1,
              ssh_keepers: 3,
              ssh_unbound_keepers: 0,
              ssh_active_sessions: null,
              ssh_max_sessions: 8,
              docker_keepers: 1,
            },
            shim_parity: {
              status: 'matched',
              build_identity: 'sha-abc123',
              shim_identity: 'sha-abc123',
              server_identity: 'sha-abc123',
            },
            microvm_guests: [{ id: 'vm-1', keeper: 'sangsu', state: 'running', socket_present: true, shim_parity: 'matched', pid: 4412 }],
            ssh_pools: [{ id: 'pool-a', host: 'ssh.internal', rtt_ms: 14, active_sessions: null, max_sessions: 8, keepers: ['sangsu'] }],
            ssh_unbound_keepers: [],
            docker_keepers: [{ keeper: 'dreamer', container_id: 'c-99', image: 'masc:latest', status: 'running' }],
            volume_gc_report: { reclaimed_bytes: 0 },
            host_storage: { free_gb: 120 },
            unobserved_reasons: [{ scope: 'ssh_active_sessions', reason: 'multiplexer telemetry disabled' }],
          },
        })
      }
      if (url === '/api/v1/infra/sandboxes/probe' && method === 'POST') {
        return jsonResponse({ ok: true })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${InfraWorkspace} subroute="sandboxes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    expect(container.querySelector('[data-testid="sandbox-probe-state"]')!.textContent).toContain('fresh')
    expect(container.querySelector('[data-testid="sandbox-shim-parity"]')!.textContent).toContain('matched')
    expect(container.querySelector('[data-testid="sandbox-unobserved-reasons"]')!.textContent).toContain('multiplexer telemetry disabled')
    // ssh_active_sessions: null MUST display "미보고", never "0"
    expect(container.textContent).toContain('미보고 / 8')

    const probeBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('지금 프로브 실행'),
    ) as HTMLButtonElement
    probeBtn.click()
    await flushUi(30)

    expect(calls.some((c) => c.url === '/api/v1/infra/sandboxes/probe' && c.method === 'POST')).toBe(true)
  })

  it('reports repository access failure instead of an empty registration list', async () => {
    globalThis.fetch = vi.fn(async () => jsonResponse({ error: 'repository access denied' }, 403)) as typeof fetch
    render(html`<${InfraWorkspace} subroute="repos" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi()

    expect(container.querySelector('[role="alert"]')?.textContent).toContain('저장소 조회 실패')
    expect(container.textContent).not.toContain('등록된 저장소가 없습니다.')
  })

  it('fetches Repos and ALWAYS passes repo_id to /api/v1/ide/repository-activity (OkData), rendering diff & [⤢] inspect drawer', async () => {
    const seenUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      seenUrls.push(url)
      if (url === '/api/v1/repositories') {
        return jsonResponse({
          repositories: [{
            id: 'repo-masc',
            name: 'masc',
            url: 'https://github.com/jeong-sik/masc',
            local_path: '/workspace/masc',
            default_branch: 'main',
            status: 'active',
            auto_sync: true,
            sync_interval: 300,
          }],
        })
      }
      if (url.startsWith('/api/v1/ide/repository-activity')) {
        return jsonResponse({
          ok: true,
          data: {
            repo_id: 'repo-masc',
            window_hours: 24,
            incomplete: 0,
            unattributed: 0,
            changes: [{
              at: 1_700_000_123,
              keeper: 'code-reviewer-sister',
              turn: 42,
              task_id: 'task-7',
              execution_id: 'exec-1',
              line_evidence: null,
              location: { path: 'lib/example.ml' },
              change: { before: 'let x = 1\n', after: 'let x = 2\n' },
              succeeded: true,
            }],
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    const inspected: WorkspaceInspectPayload[] = []
    render(
      html`<${InfraWorkspace} subroute="repos" onNavigate=${vi.fn()} onInspect=${(p: WorkspaceInspectPayload) => inspected.push(p)} />`,
      container,
    )
    await flushUi(50)

    expect(seenUrls).toContain('/api/v1/ide/repository-activity?repo_id=repo-masc&window_hours=24')
    expect(container.textContent).toContain('lib/example.ml')
    expect(container.textContent).toContain('+let x = 2')

    const inspectBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('[⤢] 전체 Diff'),
    ) as HTMLButtonElement
    inspectBtn.click()

    expect(inspected).toHaveLength(1)
    expect(inspected[0]!.kind).toBe('repo_diff')
    expect(inspected[0]!.title).toBe('lib/example.ml')
  })

  it.each([
    { status: 200, label: 'SNAPSHOT' },
    { status: 403, label: 'UNAVAILABLE' },
  ])('uses the authorized Logs read in an account session (HTTP $status)', async ({ status, label }) => {
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'operator-1',
      email: 'operator@example.com',
      displayName: 'Operator',
      role: 'admin',
      csrfToken: 'fixture-csrf',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    }
    setObserverSseInstanceId('account-observer.1')
    const request = vi.fn(async () => status === 200
      ? jsonResponse({ entries: [{ seq: 1, message: 'Log snapshot row' }] })
      : jsonResponse({ error: 'Log access refused' }, status))
    globalThis.fetch = request as typeof fetch
    render(html`<${InfraWorkspace} subroute="logs" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await vi.waitFor(() => {
      expect(container.querySelector('[data-testid="logs-stream-status"]')?.textContent).toContain(label)
    })

    expect(activeViewStreamKey.value).toBeNull()
    expect(request.mock.calls).toHaveLength(1)
    expect(request).toHaveBeenCalledWith('/api/v1/dashboard/logs?limit=200', expect.objectContaining({
      credentials: 'same-origin',
    }))
    expect(container.querySelector('[role="alert"]')?.textContent ?? null)
      .toBe(status === 200 ? null : '로그 조회 실패: Log access refused')
    if (status === 200) expect(container.textContent).toContain('Log snapshot row')
    else expect(container.textContent).not.toContain('표시할 로그 또는 이벤트가 없습니다.')
  })

  it('virtualizes 300+ Activity & Logs rows under <1,000 DOM nodes and holds single infra-logs view stream', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: false,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    const entries = Array.from({ length: 300 }, (_, i) => ({
      seq: 1000 - i,
      ts: new Date(1_700_000_000_000 - i * 1000).toISOString(),
      level: i % 5 === 0 ? 'ERROR' : 'INFO',
      source: 'structured',
      module: 'keeper_runtime',
      keeper_name: 'sangsu',
      turn_id: i,
      message: `Log line #${i}`,
      details: { index: i, phase: 'turn' },
      category: 'turn',
    }))

    registerWorkspaceTargets([{ id: 'ws-ops', label: 'Ops', baseUrl: '/ws/ops' }])
    selectWorkspace('ws-ops')
    setObserverSseInstanceId('inst-live-infra.9')

    const seenStreamCalls: { url: string; instanceHeader: string | undefined }[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/api/v1/dashboard/logs/stream')) {
        const hdrs = (init?.headers ?? {}) as Record<string, string>
        seenStreamCalls.push({ url, instanceHeader: hdrs[OBSERVER_SSE_INSTANCE_HEADER] })
        return pendingSseResponse()
      }
      if (url.includes('/api/v1/dashboard/logs')) {
        return jsonResponse({ entries })
      }
      return jsonResponse({})
    }) as typeof fetch

    const onInspect = vi.fn()
    render(
      html`<${InfraWorkspace} subroute="logs" onNavigate=${vi.fn()} onInspect=${onInspect} />`,
      container,
    )
    await flushUi(50)

    expect(activeViewStreamKey.value).toBe('infra-logs')
    expect(seenStreamCalls).toEqual([
      { url: '/ws/ops/api/v1/dashboard/logs/stream?limit=200', instanceHeader: 'inst-live-infra.9' },
    ])
    // VirtualList MUST keep DOM strictly under 1,000 nodes even for 300+ log rows!
    expect(container.querySelectorAll('*').length).toBeLessThan(1000)
    const renderedLogRows = container.querySelectorAll('.v2-logs-row').length
    expect(renderedLogRows).toBeGreaterThan(0)
    expect(renderedLogRows).toBeLessThan(60)

    // Clicking a row opens K/V detail inspector & calls onInspect
    ;(container.querySelector('.v2-logs-row') as HTMLElement).click()
    await flushUi(15)
    expect(container.querySelector('[data-testid="logs-kv-inspector"]')).not.toBeNull()
    expect(onInspect).toHaveBeenCalledTimes(1)

    // Pause toggle pauses live updates and buffers incoming events until resumed
    const pauseBtn = container.querySelector('[data-testid="logs-pause-toggle"]') as HTMLButtonElement
    expect(pauseBtn).not.toBeNull()
    expect(pauseBtn.getAttribute('aria-pressed')).toBe('false')
    pauseBtn.click()
    await flushUi(10)
    expect(pauseBtn.getAttribute('aria-pressed')).toBe('true')
    expect(container.querySelector('[data-testid="logs-stream-status"]')?.textContent).toContain('PAUSED')

    pauseBtn.click()
    await flushUi(10)
    expect(pauseBtn.getAttribute('aria-pressed')).toBe('false')
  })
})
