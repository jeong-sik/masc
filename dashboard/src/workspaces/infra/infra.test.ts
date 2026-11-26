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
import { OBSERVER_IDLE_TIMEOUT_HEADER } from '../../lib/observer-protocol'
import { resetShellStateForTests, shellToasts } from '../../shell/shell-state'
import { InfraWorkspace, type WorkspaceInspectPayload } from './index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

const TEST_LOG_INSTANCE = 'inst-live-infra.9'

function logsSseHeaders(idleTimeoutMs = 30_000): Record<string, string> {
  return {
    'Content-Type': 'text/event-stream',
    [OBSERVER_SSE_INSTANCE_HEADER]: TEST_LOG_INSTANCE,
    [OBSERVER_IDLE_TIMEOUT_HEADER]: String(idleTimeoutMs),
  }
}

function pendingSseResponse(): Response {
  const stream = new ReadableStream<Uint8Array>({
    start() { /* hold open until aborted */ },
  })
  return new Response(stream, {
    status: 200,
    headers: logsSseHeaders(),
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
    resetShellStateForTests()
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
    expect(shellToasts.value.some((t) => t.tone === 'success' && t.message.includes('샌드박스 프로브'))).toBe(true)
  })

  it('renders authoritative OCaml sandboxes wire objects without [object Object] for microvm_guests, ssh_pools, and docker_keepers', async () => {
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/api/v1/infra/sandboxes') {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-2',
          generated_at_unix: 1_700_000_100,
          data: {
            probe_state: { kind: 'fresh', measured_at_unix: 1_700_000_100 },
            summary: {
              microvm_declared: 1,
              microvm_running: 1,
              microvm_sockets_present: 1,
              microvm_shim_mismatch: 1,
              ssh_pools: 2,
              ssh_keepers: 2,
              ssh_unbound_keepers: 0,
              ssh_active_sessions: null,
              ssh_max_sessions: 10,
              docker_keepers: 1,
            },
            shim_parity: {
              status: 'mismatch',
              shim_identity: 'sha-shim-1',
              server_identity: 'sha-srv-2',
            },
            microvm_guests: [
              {
                keeper: 'e-masc-the-leader',
                backend: 'apple_container',
                guest_name: 'masc-vm-e-masc-the-leader',
                presence: 'present',
                agent_socket: {
                  status: 'socket_present',
                  exists: true,
                  path_basename: 'agent.sock',
                },
                shim_parity: {
                  status: 'mismatch',
                  shim_identity: 'sha-shim-1',
                  server_identity: 'sha-srv-2',
                },
                network_mode: 'none',
                guest_size: { cpus: 2, memory_mib: 2048 },
                volume: { name: 'masc-work-leader', status: 'declared' },
              },
            ],
            ssh_pools: [
              {
                pool_name: 'mac-worker-1',
                host: '127.0.0.1',
                port: 2222,
                unix_user: 'dancer',
                remote_root: '/srv/masc',
                private_home: true,
                max_sessions: 8,
                active_sessions: null,
                reachability: { status: 'reachable', rtt_ms: 1.4, measured_at_unix: 1_700_000_100 },
                accounts: [{ unix_user: 'dancer', active_sessions: null, max_sessions: 8, keepers: ['alpha', 'beta'] }],
                keeper_sessions: [
                  { keeper: 'alpha', last_dispatch: null },
                  { keeper: 'beta', last_dispatch: null },
                ],
              },
              {
                pool_name: 'mac-worker-2',
                host: '127.0.0.1',
                port: 2223,
                unix_user: 'dancer',
                max_sessions: 2,
                active_sessions: null,
                reachability: { status: 'unreachable', detail: 'Connection refused', measured_at_unix: 1_700_000_100 },
                accounts: [{ unix_user: 'dancer', active_sessions: null, max_sessions: 2, keepers: [] }],
                keeper_sessions: [],
              },
            ],
            ssh_unbound_keepers: [],
            docker_keepers: [
              { keeper: 'dock-bot', backend: 'docker', network_mode: 'bridge' },
            ],
            volume_gc_report: null,
            host_storage: null,
            unobserved_reasons: [{ scope: 'remote_ssh_sessions', reason: 'ssh_active_sessions_unreported' }],
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${InfraWorkspace} subroute="sandboxes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    const text = container.textContent ?? ''
    expect(text).not.toContain('[object Object]')
    // MicroVM OCaml wire fields rendered cleanly
    expect(text).toContain('e-masc-the-leader')
    expect(text).toContain('present')
    expect(text).toContain('mismatch')
    expect(text).toContain('apple_container · 2c / 2048MiB · net:none')
    // SSH pool OCaml wire fields rendered cleanly
    expect(text).toContain('mac-worker-1')
    expect(text).toContain('dancer@127.0.0.1:2222')
    expect(text).toContain('1.4ms')
    expect(text).toContain('mac-worker-2')
    expect(text).toContain('연결 불가')
    expect(text).toContain('미보고 / 8')
    // Docker OCaml wire fields rendered cleanly
    expect(text).toContain('dock-bot')
    expect(text).toContain('bridge')
  })

  it('renders ssh_unbound_keepers and wires sandbox/keeper settings deep links', async () => {
    const navCalls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/api/v1/infra/sandboxes') {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-3',
          generated_at_unix: 1_700_000_200,
          data: {
            probe_state: { kind: 'fresh', measured_at_unix: 1_700_000_200 },
            summary: {
              microvm_declared: 1,
              microvm_running: 1,
              microvm_sockets_present: 1,
              microvm_shim_mismatch: 0,
              ssh_pools: 1,
              ssh_keepers: 1,
              ssh_unbound_keepers: 1,
              ssh_active_sessions: null,
              ssh_max_sessions: 4,
              docker_keepers: 0,
            },
            shim_parity: { status: 'matched' },
            microvm_guests: [{ keeper: 'vm-bot', backend: 'apple_container', presence: 'present' }],
            ssh_pools: [{
              pool_name: 'apple-wkbl',
              host: '127.0.0.1',
              port: 22267,
              unix_user: 'masc-ssh',
              max_sessions: 4,
              active_sessions: null,
              keeper_sessions: [{ keeper: 'wkbl-front', last_dispatch: null }],
            }],
            ssh_unbound_keepers: [{
              keeper: 'orphan-ssh',
              backend: 'remote_ssh',
              binding_state: 'unbound',
              remote_endpoint: null,
            }],
            docker_keepers: [],
            volume_gc_report: null,
            host_storage: null,
            unobserved_reasons: [],
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${InfraWorkspace} subroute="sandboxes" onNavigate=${(p: string) => navCalls.push(p)} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    const unboundSec = container.querySelector('[data-testid="sandbox-ssh-unbound"]')
    expect(unboundSec).not.toBeNull()
    expect(unboundSec?.textContent).toContain('orphan-ssh')

    const settingsBtn = container.querySelector<HTMLButtonElement>('[data-testid="sandbox-settings-btn"]')!
    settingsBtn.click()
    const unboundCfgBtn = [...unboundSec!.querySelectorAll<HTMLButtonElement>('button')]
      .find((b) => b.textContent?.includes('키퍼 설정'))!
    unboundCfgBtn.click()
    const poolChip = container.querySelector<HTMLButtonElement>('.v2-sandbox-keeper-chip')!
    poolChip.click()

    expect(navCalls).toEqual([
      '/settings?section=sandbox',
      '/keepers/orphan-ssh/config?section=sandbox',
      '/keepers/wkbl-front/config?section=sandbox',
    ])
  })

  it('handles absent and malformed/whitespace ssh_unbound_keepers rows safely without crashing or emitting broken routes', async () => {
    const navCalls: string[] = []
    let payloadMode: 'absent' | 'malformed' = 'absent'
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/api/v1/infra/sandboxes') {
        const base = {
          probe_state: { kind: 'fresh', measured_at_unix: 1_700_000_250 },
          summary: {
            microvm_declared: 0,
            microvm_running: 0,
            microvm_sockets_present: 0,
            microvm_shim_mismatch: 0,
            ssh_pools: 1,
            ssh_keepers: 1,
            ssh_unbound_keepers: payloadMode === 'absent' ? 0 : 2,
            ssh_active_sessions: null,
            ssh_max_sessions: 4,
            docker_keepers: 0,
          },
          shim_parity: { status: 'matched' },
          microvm_guests: [{ keeper: '   ', guest_name: 'vm-blank', presence: 'present' }],
          ssh_pools: [{
            pool_name: 'pool-dedupe',
            host: '127.0.0.1',
            max_sessions: 4,
            active_sessions: null,
            keepers: [' dup-keeper ', 'dup-keeper', '   '],
          }],
          docker_keepers: [],
          volume_gc_report: null,
          host_storage: null,
          unobserved_reasons: [],
        }
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-4',
          generated_at_unix: 1_700_000_250,
          data: payloadMode === 'absent'
            ? base
            : {
                ...base,
                ssh_unbound_keepers: [
                  { keeper: '   ', binding_state: '', remote_endpoint: '' },
                  { keeper: ' valid-ssh ', binding_state: 'unbound', remote_endpoint: '' },
                ],
              },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${InfraWorkspace} subroute="sandboxes" onNavigate=${(p: string) => navCalls.push(p)} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)
    expect(container.querySelector('[data-testid="sandbox-ssh-unbound"]')).toBeNull()
    // Duplicate / whitespace keepers in pool deduped to single chip
    const chips = container.querySelectorAll('.v2-sandbox-keeper-chip')
    expect(chips).toHaveLength(1)
    expect(chips[0]?.textContent?.trim()).toBe('dup-keeper')

    // Reload with malformed unbound rows -> blank row has no broken action button; trimmed valid row navigates cleanly
    payloadMode = 'malformed'
    resourceCache.clearAll()
    render(null, container)
    render(
      html`<${InfraWorkspace} subroute="sandboxes" onNavigate=${(p: string) => navCalls.push(p)} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    const unboundSec = container.querySelector('[data-testid="sandbox-ssh-unbound"]')!
    expect(unboundSec).not.toBeNull()
    expect(unboundSec.textContent).toContain('없음')
    expect(unboundSec.textContent).toContain('미지정')
    const cfgBtns = [...unboundSec.querySelectorAll<HTMLButtonElement>('button')].filter((b) =>
      b.textContent?.includes('키퍼 설정'),
    )
    expect(cfgBtns).toHaveLength(1)
    cfgBtns[0]!.click()
    expect(navCalls).toEqual(['/keepers/valid-ssh/config?section=sandbox'])
  })

  it('pushes success shell toast on repository sync without inline banner jump', async () => {
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
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
      if (url === '/api/v1/repositories/repo-masc/sync' && init?.method === 'POST') {
        return jsonResponse({ ok: true })
      }
      if (url.startsWith('/api/v1/ide/repository-activity')) {
        return jsonResponse({ ok: true, data: { repo_id: 'repo-masc', window_hours: 24, incomplete: 0, unattributed: 0, changes: [] } })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(html`<${InfraWorkspace} subroute="repos" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi(40)

    const syncBtn = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
      b.textContent?.includes('동기화'),
    )!
    syncBtn.click()
    await flushUi(30)

    expect(shellToasts.value.some((t) => t.tone === 'success' && t.message.includes('repo-masc 동기화 완료'))).toBe(true)
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

  describe('Activity & Logs read overlap', () => {
    const oldLog = { seq: 10, ts: '2026-11-25T00:00:00Z', message: 'retired fixture row' }
    const liveLog = { seq: 11, ts: '2026-11-25T00:00:01Z', message: 'current fixture row' }

    function openTimeline(snapshot: Promise<Response>, idleTimeoutMs?: number) {
      authSession.value = {
        kind: 'single_user_local',
        mode: 'single_user',
        tokenPresent: false,
        authMethods: { google: false, github: false, dev_token: false },
        workspaceId: 'default',
      }
      setObserverSseInstanceId(TEST_LOG_INSTANCE)
      let controller!: ReadableStreamDefaultController<Uint8Array>
      const makeStream = () => new ReadableStream<Uint8Array>({ start: current => { controller = current } })
      let stream = makeStream()
      let streamRequests = 0
      globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
        if (String(input).includes('/api/v1/dashboard/logs/stream')) {
          if (streamRequests++ > 0) stream = makeStream()
          return new Response(stream, { headers: logsSseHeaders(idleTimeoutMs) })
        }
        return snapshot
      }) as typeof fetch
      render(html`<${InfraWorkspace} subroute="logs" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
      return {
        streamRequests: () => streamRequests,
        send: (reset: boolean, entries: readonly object[]) => {
          controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({ reset, entries })}\n\n`))
        },
        close: () => controller.close(),
      }
    }

    it('uses the stream after its first sample and keeps one row per log sequence', async () => {
      let finishSnapshot!: (response: Response) => void
      const timeline = openTimeline(new Promise(resolve => { finishSnapshot = resolve }))

      timeline.send(true, [liveLog])
      await vi.waitFor(() => expect(container.textContent).toContain(liveLog.message))
      finishSnapshot(jsonResponse({ entries: [oldLog] }))
      timeline.send(false, [
        { seq: 12, ts: '2026-11-25T00:00:02Z', message: 'next fixture row' },
        liveLog,
      ])
      timeline.close()

      await vi.waitFor(() => expect(container.textContent).toContain('next fixture row'))
      await flushUi()
      expect(container.textContent).not.toContain(oldLog.message)
      const rows = Array.from(container.querySelectorAll('.v2-logs-row'))
      expect(rows.filter(row => row.textContent?.includes(liveLog.message))).toHaveLength(1)
      expect(container.querySelector('[data-testid="logs-stream-status"] time')?.getAttribute('datetime')).toBeTruthy()
    })

    it('applies a buffered stream reset even when no rows follow it', async () => {
      const timeline = openTimeline(Promise.resolve(jsonResponse({ entries: [oldLog] })))
      await vi.waitFor(() => expect(container.textContent).toContain(oldLog.message))
      const pause = container.querySelector<HTMLButtonElement>('[data-testid="logs-pause-toggle"]')!
      pause.click()
      await vi.waitFor(() => expect(pause.getAttribute('aria-pressed')).toBe('true'))

      timeline.send(true, [])
      await flushUi()
      expect(container.textContent).toContain(oldLog.message)
      pause.click()
      await flushUi()

      expect(container.textContent).not.toContain(oldLog.message)
      timeline.close()
    })

    it('requires a log sample before LIVE and lets an idle stream be retried', async () => {
      const timeline = openTimeline(Promise.resolve(jsonResponse({ entries: [oldLog] })), 250)
      const status = () => container.querySelector('[data-testid="logs-stream-status"]')?.textContent
      const retry = () => [...container.querySelectorAll('button')].find(button => button.textContent?.includes('다시 연결'))

      await vi.waitFor(() => expect(timeline.streamRequests()).toBe(1))
      expect(status()).toContain('CONNECTING')
      await vi.waitFor(() => expect(retry()).toBeDefined())
      expect(status()).toContain('SNAPSHOT')
      expect(container.textContent).toContain(oldLog.message)
      retry()!.click()
      await vi.waitFor(() => expect(timeline.streamRequests()).toBe(2))
      expect(status()).toContain('CONNECTING')

      timeline.send(true, [liveLog])
      await vi.waitFor(() => expect(status()).toContain('LIVE SSE'))
      expect(container.textContent).toContain(liveLog.message)
      expect(container.textContent).not.toContain(oldLog.message)
      await vi.waitFor(() => expect(retry()).toBeDefined())
      expect(status()).toContain('SNAPSHOT')
      expect(container.textContent).toContain(liveLog.message)
    })
  })
})
