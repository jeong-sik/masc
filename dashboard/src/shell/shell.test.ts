// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { act, fireEvent, waitFor } from '@testing-library/preact'
import {
  activeWorkspaceId,
  authSession,
  bumpSessionEpoch,
  registerWorkspaceTargets,
  resetAuthStateForTests,
  selectWorkspace,
  sessionEpoch,
} from '../core/auth'
import {
  observerConnected,
  resetObserverStateForTests,
  viewProvenance,
} from '../core/observer'
import { resourceCache } from '../core/resource-cache'
import { resetTimeWindowForTests, timeWindow } from '../core/time-window'
import { apiMutate } from '../core/transport'
import { subscribeActiveSchedulesRefresh } from '../components/schedule/schedule-state'
import { publishDashboardObservationChange } from '../lib/observation-refresh'
import { confirmRuntimeTestWorkspace } from '../lib/runtime-workspace.test-fixture'
import { navigate, resetRouterForTests } from '../routes/router'
import { CommandPalette, buildPaletteCommands } from './command-palette'
import { FastApprovalStrip } from './fast-approval-strip'
import { IncidentsOverlayBody } from './incidents-overlay'
import { MobileNav } from './mobile-nav'
import { NavRail } from './nav-rail'
import { QueueContextOverlayBody } from './queue-context-overlay'
import {
  activeOverlay,
  commandPaletteOpen,
  effectiveHitlSourceStatus,
  historicalIncidents,
  inboxPendingCount,
  openInspectDrawer,
  parseAwaitingGoalsPayload,
  parseGateQueuePayload,
  parseKeeperAsksPayload,
  parsePendingVerificationsPayload,
  pendingApprovals,
  pendingGateApprovals,
  pendingGoalConfirmations,
  pendingVerifications,
  railExpanded,
  recordIncident,
  refreshPendingHitl,
  resetShellStateForTests,
  toggleRail,
  unreadIncidentCount,
  viewportWidth,
} from './shell-state'
import { TopBar } from './top-bar'

const AUTH_METHODS = { google: true, github: true, dev_token: false } as const

const EMPTY_HITL: Readonly<Record<string, object>> = {
  '/api/v1/keepers/tool-approvals': { pending: [] },
  '/api/v1/keepers/asks': { asks: [] },
  '/api/v1/dashboard/gate': { approval_queue: [] },
  '/api/v1/dashboard/planning': { goals: [] },
  '/api/v1/verification/requests': { requests: [] },
}

const EMPTY_ACTIVE_SCHEDULES = {
  status: 'ok',
  schedule_store_known: true,
  schedule_store_read_error: null,
  active_only_selector: true,
  request_count: 0,
  request_limit: 20,
  truncated: false,
  counts: {},
  fsm: { state: 'idle', active_count: 0, terminal_count: 0 },
  requests: [],
}

function hitlJson(payload: object, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } })
}

describe('Proposal A+ Shell components', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetTimeWindowForTests('24h')
    resetRouterForTests('/pulse')
    resetShellStateForTests()
    resourceCache.clearAll()
    confirmRuntimeTestWorkspace()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.restoreAllMocks()
  })

  it('NavRail renders 6 trunks + 2 footer anchors, toggles collapse, auto-collapses <=1440px on drawer open, and marks Admin locks for Workers', async () => {
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'u-worker-1',
      email: 'w@example.com',
      displayName: 'worker-kim',
      role: 'worker',
      csrfToken: 'csrf-1',
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    viewportWidth.value = 1440

    await act(async () => {
      render(h(NavRail, {}), container)
    })

    const rail = container.querySelector('.ap-rail')
    expect(rail?.getAttribute('data-expanded')).toBe('true')
    expect(container.querySelectorAll('.ap-rail-trunks .ap-rail-item')).toHaveLength(6)
    expect(container.querySelectorAll('.ap-rail-footer .ap-rail-item')).toHaveLength(2)

    // Worker sees explicit RBAC lock signifiers on Infra & Settings
    expect(container.querySelector('[data-nav-id="infra"]')?.getAttribute('data-rbac-locked')).toBe('true')
    expect(container.querySelector('[data-nav-id="settings"]')?.getAttribute('data-rbac-locked')).toBe('true')
    expect(container.querySelector('[data-nav-id="pulse"]')?.hasAttribute('data-rbac-locked')).toBe(false)

    // Opening Quick-Peek at <=1440px auto-collapses rail to 56px
    await act(async () => {
      openInspectDrawer({ title: 'Diff', kind: 'diff', data: {} })
    })
    expect(railExpanded.value).toBe(false)
    expect(container.querySelector('.ap-rail')?.getAttribute('data-expanded')).toBe('false')

    // Closing overlay restores expanded preference; toggleRail collapses explicitly
    await act(async () => {
      activeOverlay.value = null
    })
    expect(railExpanded.value).toBe(true)
    await act(async () => {
      toggleRail()
    })
    expect(railExpanded.value).toBe(false)
  })

  it('TopBar switches workspace targets (bumping sessionEpoch), shows Time-Window pill on telemetry routes only, and opens provenance popover', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    registerWorkspaceTargets([
      { id: 'default', label: 'Primary Local' },
      { id: 'staging', label: 'Staging MASC', baseUrl: 'http://127.0.0.1:8940' },
    ])

    await act(async () => {
      render(h(TopBar, {}), container)
    })

    // On /pulse -> time window pill is visible
    expect(container.querySelector('[data-testid="time-window-pill"]')).not.toBeNull()
    const btn7d = [...container.querySelectorAll('.ap-win-btn')].find((b) => b.textContent === '7d') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(btn7d)
    })
    expect(timeWindow.value).toBe('7d')

    // Navigate to /settings (non-telemetry) -> time window pill hides
    await act(async () => {
      navigate('/settings')
    })
    expect(container.querySelector('[data-testid="time-window-pill"]')).toBeNull()

    // Provenance pill opens connection/build popover (no permanent amber top warning banner)
    const provBtn = container.querySelector('[data-testid="provenance-pill"]') as HTMLButtonElement
    expect(provBtn.getAttribute('data-provenance')).toBe('SNAPSHOT')
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({ version: '0.81.0' }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    }))
    await act(async () => {
      fireEvent.click(provBtn)
    })
    expect(container.querySelector('.ap-prov-popover')).not.toBeNull()

    // Switch workspace via Top-Left switcher -> bumps sessionEpoch!
    const beforeEpoch = sessionEpoch.value
    const trigger = container.querySelector('[data-testid="account-workspace-switcher"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(trigger)
    })
    const stagingBtn = container.querySelector('[data-workspace-target="staging"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(stagingBtn)
    })
    expect(activeWorkspaceId.value).toBe('staging')
    expect(sessionEpoch.value).toBeGreaterThan(beforeEpoch)
  })

  it('reports unread and inaccessible HITL sources until a successful empty read', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }

    let release!: () => void
    const firstRead = new Promise<void>((resolve) => { release = resolve })
    let recovered = false
    const blockedStatuses: Readonly<Record<string, number>> = {
      '/api/v1/keepers/tool-approvals': 404,
      '/api/v1/keepers/asks': 403,
      '/api/v1/dashboard/gate': 404,
      '/api/v1/dashboard/planning': 403,
      '/api/v1/verification/requests': 404,
    }
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const path = new URL(String(input), location.href).pathname
      const status = blockedStatuses[path]
      if (status && !recovered) {
        await firstRead
        return hitlJson({ error: 'HITL source unavailable' }, status)
      }
      return hitlJson(EMPTY_HITL[path] ?? {})
    })

    await act(async () => {
      render(h('div', {}, h(TopBar, {}), h(FastApprovalStrip, {}), h(QueueContextOverlayBody, {})), container)
    })
    const askEmpty = '대기 중인 Keeper 질문이 없습니다.'
    const strip = () => container.querySelector('[data-testid="fast-approval-strip"]')
    const inboxBadge = () => container.querySelector('[data-testid="inbox-pill"] .ap-pill-count')?.textContent
    expect(container.textContent).toContain('Pending Tool Approvals (조회 대기)')
    expect(container.textContent).toContain('Open Keeper Asks (조회 대기)')
    expect(container.textContent).not.toContain(askEmpty)
    expect(strip()?.textContent).toContain('일부 미확인')
    expect(inboxBadge()).toBe('?')

    release()
    await waitFor(() => {
      expect(container.textContent).toContain('Pending Tool Approvals (조회 실패)')
      expect(container.textContent).toContain('Open Keeper Asks (조회 실패)')
      expect(container.textContent).toContain('Channel Gate Approvals (조회 실패)')
      expect(container.textContent).toContain('Goal Confirmations (조회 실패)')
      expect(container.textContent).toContain('Awaiting Verifications (조회 실패)')
    })
    expect(container.textContent).not.toContain(askEmpty)
    expect(strip()?.textContent).toContain('일부 미확인')
    expect(inboxBadge()).toBe('?')

    recovered = true
    await act(async () => { await refreshPendingHitl() })
    expect(container.textContent).toContain(askEmpty)
    expect(strip()).toBeNull()
    expect(inboxBadge()).toBe('0')
  })

  it('FastApprovalStrip renders 0px when clear, wraps mutations in TargetLockedAction, and locks on sessionEpoch drift', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }

    const fetchEmpty: typeof fetch = async (input) => hitlJson(EMPTY_HITL[new URL(String(input), location.href).pathname] ?? {})
    await refreshPendingHitl(fetchEmpty)
    await act(async () => {
      render(h(FastApprovalStrip, {}), container)
    })
    // 0px when clear
    expect(container.querySelector('[data-testid="fast-approval-strip"]')).toBeNull()

    // Add a pending approval -> strip mounts with immutable TargetLockedAction metadata
    await act(async () => {
      pendingApprovals.value = [{
        approvalId: 'apr-42',
        keeper: 'code-reviewer-sister',
        toolCallId: 'tc-99',
        tool: 'git_push',
        args: '{}',
        question: 'Allow git push?',
        because: 'needs approval',
        askedAt: 1700000000,
        workspaceId: 'default',
        revision: 'rev-7',
      }]
    })

    const strip = container.querySelector('[data-testid="fast-approval-strip"]')
    expect(strip).not.toBeNull()
    expect(strip?.textContent).toContain('workspace_id:')
    expect(strip?.textContent).toContain('code-reviewer-sister')
    expect(strip?.textContent).toContain('apr-42')
    expect(strip?.textContent).toContain('rev-7')

    const tla = strip?.querySelector('.tla')
    expect(tla?.getAttribute('data-locked')).toBe('false')

    // Bumping sessionEpoch immediately locks the TargetLockedAction!
    await act(async () => {
      bumpSessionEpoch()
    })
    expect(strip?.querySelector('.tla')?.getAttribute('data-locked')).toBe('true')
    const approveBtn = strip?.querySelector('.btn-primary') as HTMLButtonElement
    expect(approveBtn.disabled).toBe(true)
  })

  it('CommandPalette indexes all A+ routes, Account:/Provider:/Setting: namespaces, and Theme/HC toggles', async () => {
    const cmds = buildPaletteCommands(authSession.value)
    expect(cmds.some((c) => c.label.startsWith('Account:'))).toBe(true)
    expect(cmds.some((c) => c.label.startsWith('Provider:'))).toBe(true)
    expect(cmds.some((c) => c.label.startsWith('Setting:'))).toBe(true)
    expect(cmds.some((c) => c.id === 'theme:high-contrast')).toBe(true)

    commandPaletteOpen.value = true
    await act(async () => {
      render(h(CommandPalette, {}), container)
    })

    const input = container.querySelector('.ap-cmdk-input') as HTMLInputElement
    await act(async () => {
      fireEvent.input(input, { target: { value: 'High-Contrast' } })
    })
    const hcItem = container.querySelector('[data-command-id="theme:high-contrast"]') as HTMLButtonElement
    expect(hcItem).not.toBeNull()
    await act(async () => {
      fireEvent.click(hcItem)
    })
    expect(document.documentElement.dataset.contrast).toBe('high')
    expect(commandPaletteOpen.value).toBe(false)
  })

  it('Channel 3 Incidents overlay stays strictly isolated from Channel 2 Live SSOT', async () => {
    const beforeProv = viewProvenance.value
    const beforeConn = observerConnected.value
    recordIncident({
      severity: 'error',
      source: 'transport',
      summary: '503 upstream timeout',
      detail: 'GET /api/v1/dashboard/shell',
    })
    expect(unreadIncidentCount.value).toBe(1)
    expect(viewProvenance.value).toBe(beforeProv)
    expect(observerConnected.value).toBe(beforeConn)

    await act(async () => {
      render(h(IncidentsOverlayBody, {}), container)
    })
    expect(container.textContent).toContain('503 upstream timeout')
    const dismissBtn = container.querySelector('.ap-inc-actions button') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(dismissBtn)
    })
    expect(historicalIncidents.value[0]?.dismissed).toBe(true)
  })

  it('parseKeeperAsksPayload filters live resolution.state (excludes answered/withdrawn, keeps open)', () => {
    const parsed = parseKeeperAsksPayload({
      asks: [
        { ask_id: 'ask-open', keeper: 'k1', resolution: { state: 'open' }, question: 'Continue?' },
        { ask_id: 'ask-ans', keeper: 'k1', resolution: { state: 'answered' }, question: 'Done?' },
        { ask_id: 'ask-wd', keeper: 'k2', resolution: { state: 'withdrawn' }, question: 'Cancelled?' },
      ],
    }, 'default')
    expect(parsed.map((a) => a.askId)).toEqual(['ask-open'])
  })

  it('MobileNav renders 4 primary tabs + More sheet with 44px touch-target classes', async () => {
    await act(async () => {
      render(h(MobileNav, {}), container)
    })
    expect(container.querySelectorAll('.ap-mobile-tab')).toHaveLength(5)
    expect(container.querySelectorAll('.ap-mobile-tab.ap-touch-target')).toHaveLength(5)

    const moreBtn = container.querySelector('[data-testid="mobile-more-trigger"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(moreBtn)
    })
    expect(container.querySelector('[data-testid="mobile-more-sheet"]')).not.toBeNull()
  })

  it('CommandPalette ignores IME composing Enter, scrolls active option into view on ArrowDown, and FastApprovalStrip ignores shortcuts while palette is open', async () => {
    commandPaletteOpen.value = true
    pendingApprovals.value = [{
      approvalId: 'apr-ime-1',
      keeper: 'code-reviewer-sister',
      toolCallId: 'tc-ime-1',
      tool: 'git_push',
      args: '{}',
      question: 'Allow?',
      because: 'guard',
      askedAt: 1700000000,
      workspaceId: 'default',
      revision: 'rev-1',
    }]
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('{}', { status: 200 }))
    const scrollSpy = vi.fn()
    HTMLElement.prototype.scrollIntoView = scrollSpy

    await act(async () => {
      render(h('div', {}, h(FastApprovalStrip, {}), h(CommandPalette, {})), container)
    })

    const dialog = container.querySelector('.ap-cmdk-dialog') as HTMLElement
    // IME composing Enter must NOT execute or close CommandPalette
    await act(async () => {
      fireEvent.keyDown(dialog, { key: 'Enter', isComposing: true })
    })
    expect(commandPaletteOpen.value).toBe(true)

    // ArrowDown scrolls selected command into view
    scrollSpy.mockClear()
    await act(async () => {
      fireEvent.keyDown(dialog, { key: 'ArrowDown' })
    })
    expect(scrollSpy).toHaveBeenCalledWith({ block: 'nearest' })

    // FastApprovalStrip must NOT fire approval when Y is pressed while CommandPalette is open
    await act(async () => {
      fireEvent.keyDown(window, { key: 'y' })
    })
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('unifies Gate, Goal Confirmation, Verification, and Schedules across inboxPendingCount, FastApprovalStrip, and QueueContextOverlayBody', async () => {
    const gates = parseGateQueuePayload(
      { approval_queue: [{ id: 'g-1', keeper_name: 'sangsu', tool_name: 'masc_git_push', phase: 'human_required', waiting_s: 42 }] },
      'default',
    )
    const goals = parseAwaitingGoalsPayload(
      { goals: [{ id: 'goal-1', title: 'Release v0.83', phase: 'awaiting_confirmation', updated_at: '2026-11-25T00:00:00Z' }] },
      'default',
    )
    const verifs = parsePendingVerificationsPayload(
      { requests: [{ request_id: 'vr-1', task_id: 't-1', task_title: 'Verify fix', submitted_by: 'dreamer' }] },
      'default',
    )
    expect(gates).toHaveLength(1)
    expect(goals).toHaveLength(1)
    expect(verifs[0]?.worker).toBe('dreamer')

    pendingGateApprovals.value = gates
    pendingGoalConfirmations.value = goals
    pendingVerifications.value = verifs
    expect(inboxPendingCount.value).toBe(2)

    await act(async () => {
      render(h(FastApprovalStrip, {}), container)
    })
    expect(container.textContent).toContain('GATE · 2')
    expect(container.textContent).toContain('masc_git_push')

    pendingGateApprovals.value = []
    await act(async () => {
      render(h(FastApprovalStrip, {}), container)
    })
    expect(container.textContent).toContain('GOAL CONFIRM · 1')
    expect(container.textContent).toContain('Release v0.83')

    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      const json = (d: unknown) => new Response(JSON.stringify(d), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/api/v1/dashboard/shell')) return json({ counts: { keepers: 3, tasks: 7, agents: 2 } })
      if (url.includes('/api/v1/dashboard/scheduled-automation')) {
        return json({
          ...EMPTY_ACTIVE_SCHEDULES,
          request_count: 2,
          truncated: true,
          requests: [
            {
              schedule_id: 'sc-1',
              status: 'scheduled',
              payload_keeper_name: 'sangsu',
              payload_summary: 'Nightly patrol',
              next_due_at: 1795651200,
              next_due_at_iso: '2026-11-26T00:00:00Z',
            },
          ],
        })
      }
      if (url.includes('/api/v1/keepers/tool-approvals')) return json({ pending: [] })
      if (url.includes('/api/v1/keepers/asks')) return json({ asks: [] })
      if (url.includes('/api/v1/dashboard/gate')) return json({ approval_queue: [{ id: 'g-1', keeper_name: 'sangsu', tool_name: 'masc_git_push', phase: 'human_required', waiting_s: 42 }] })
      if (url.includes('/api/v1/dashboard/planning')) return json({ goals: [{ id: 'goal-1', title: 'Release v0.83', phase: 'awaiting_confirmation' }] })
      if (url.includes('/api/v1/verification/requests')) return json({ requests: [{ request_id: 'vr-1', task_id: 't-1', task_title: 'Verify fix', submitted_by: 'dreamer' }] })
      return json({})
    }))

    await act(async () => {
      render(h(QueueContextOverlayBody, {}), container)
    })
    await act(async () => {
      await new Promise((r) => setTimeout(r, 30))
    })
    expect(container.textContent).toContain('Channel Gate Approvals (1)')
    expect(container.textContent).toContain('Goal Confirmations (1)')
    expect(container.textContent).toContain('Awaiting Verifications (1)')
    expect(container.textContent).toContain('Nightly patrol')
    expect(container.textContent).toContain('due=2026-11-26T00:00:00Z')
    expect(container.textContent).toContain('표시 제한으로 일부 예약만 표시됩니다')

    // Gate unavailable reads operator_detail and deduplicates consecutive identical incidents
    const unavailFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      const json = (d: unknown) => new Response(JSON.stringify(d), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/api/v1/dashboard/gate')) {
        return json({
          approval_queue: null,
          approval_queue_state: { state: 'unavailable', operator_detail: 'gate store locked' },
        })
      }
      if (url.includes('/api/v1/keepers/tool-approvals')) return json({ pending: [] })
      if (url.includes('/api/v1/keepers/asks')) return json({ asks: [] })
      if (url.includes('/api/v1/dashboard/planning')) return json({ goals: [] })
      if (url.includes('/api/v1/verification/requests')) return json({ requests: [] })
      return json({})
    })
    resetShellStateForTests()
    await refreshPendingHitl(unavailFetch as unknown as typeof fetch)
    await refreshPendingHitl(unavailFetch as unknown as typeof fetch)
    expect(historicalIncidents.value).toHaveLength(1)
    expect(historicalIncidents.value[0]?.detail).toBe('gate store locked')
    vi.unstubAllGlobals()
  })

  it('refreshPendingHitl applies healthy sources immediately while another source hangs, then times out the hung source into an incident', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    const json = (d: unknown) =>
      new Response(JSON.stringify(d), { status: 200, headers: { 'content-type': 'application/json' } })

    const hangingFetch = vi.fn((input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/api/v1/verification/requests')) {
        // Simulate a hung endpoint that never responds (even ignores AbortSignal)
        return new Promise<Response>(() => {})
      }
      if (url.includes('/api/v1/keepers/tool-approvals')) {
        return Promise.resolve(json({
          pending: [{
            approval_id: 'apr-fast-1',
            keeper: 'sangsu',
            tool_call_id: 'tc-1',
            tool: 'git_push',
            args: '{}',
            question: 'Allow push?',
            because: 'guard',
          }],
        }))
      }
      if (url.includes('/api/v1/keepers/asks')) {
        return Promise.resolve(json({
          asks: [{ ask_id: 'ask-fast-1', keeper: 'sangsu', resolution: { state: 'open' }, question: 'Proceed?' }],
        }))
      }
      if (url.includes('/api/v1/dashboard/gate')) return Promise.resolve(json({ approval_queue: [] }))
      if (url.includes('/api/v1/dashboard/planning')) return Promise.resolve(json({ goals: [] }))
      return Promise.resolve(json({}))
    })

    const refreshPromise = refreshPendingHitl(hangingFetch as unknown as typeof fetch, { timeoutMs: 60 })
    // Even BEFORE the 60ms timeout fires on /verification/requests, approvals & asks must already be applied!
    await new Promise((r) => setTimeout(r, 15))
    expect(pendingApprovals.value.map((a) => a.approvalId)).toEqual(['apr-fast-1'])
    expect(inboxPendingCount.value).toBe(2)

    // Once the hung request hits timeoutMs, refresh finishes cleanly and records an explicit timeout incident
    await refreshPromise
    expect(historicalIncidents.value.some((inc) => inc.source === 'verification' && inc.summary.includes('timeout'))).toBe(true)
  })

  it('surfaces multi-account unbridged HITL sources and single-user fetch failures honestly in FastApprovalStrip & Quick-Peek without imposing a default timeout on apiMutate', async () => {
    // 1. P2-1: apiMutate has NO implicit 15s default timeout (must not abort slow mutations)
    vi.useFakeTimers()
    try {
      let resolveSlow!: (r: Response) => void
      const slowFetch = vi.fn(() => new Promise<Response>((r) => { resolveSlow = r }))
      const mutPromise = apiMutate('POST', '/api/v1/tools/slow_op', { ok: true }, { fetchImpl: slowFetch as unknown as typeof fetch })
      await vi.advanceTimersByTimeAsync(20_000)
      resolveSlow(new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'content-type': 'application/json' } }))
      const mutRes = await mutPromise
      expect(mutRes.ok).toBe(true)
    } finally {
      vi.useRealTimers()
    }

    // 2. P2-2: Multi-account session marks unbridged HITL sources explicitly instead of green/0px/empty
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'acc-1',
      email: 'op@example.com',
      displayName: 'Op',
      role: 'admin',
      csrfToken: 'csrf-1',
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    const requestedUrls: string[] = []
    const maFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      const json = (d: unknown) => new Response(JSON.stringify(d), { status: 200, headers: { 'content-type': 'application/json' } })
      if (url.includes('/api/v1/dashboard/shell')) return json({ counts: { keepers: 2, tasks: 4, agents: 1 } })
      if (url.includes('/api/v1/dashboard/scheduled-automation')) return json(EMPTY_ACTIVE_SCHEDULES)
      if (url.includes('/api/v1/dashboard/planning')) return json({ goals: [] })
      return json({})
    })
    vi.stubGlobal('fetch', maFetch)

    await refreshPendingHitl(maFetch as unknown as typeof fetch)
    expect(requestedUrls.some((u) => u.includes('/api/v1/keepers/tool-approvals'))).toBe(false)
    expect(requestedUrls.some((u) => u.includes('/api/v1/keepers/asks'))).toBe(false)

    await act(async () => {
      render(h('div', {}, h(FastApprovalStrip, {}), h(QueueContextOverlayBody, {})), container)
    })
    await act(async () => {
      await new Promise((r) => setTimeout(r, 30))
    })

    const strip = container.querySelector('[data-testid="fast-approval-strip"]')
    expect(strip).not.toBeNull()
    expect(strip?.getAttribute('data-hitl-unchecked')).toBe('true')
    expect(strip?.textContent).toContain('일부 미확인')
    expect(strip?.textContent).toContain('멀티 계정 미지원')

    const overlay = container.querySelector('[data-testid="queue-context-overlay"]')!
    expect(overlay.textContent).toContain('일부 미확인')
    expect(overlay.textContent).toContain('Pending Tool Approvals (멀티 계정 미지원)')
    expect(overlay.textContent).toContain('Open Keeper Asks (멀티 계정 미지원)')
    expect(overlay.textContent).toContain('Channel Gate Approvals (멀티 계정 미지원)')
    expect(overlay.textContent).not.toContain('대기 중인 도구 승인 요청이 없습니다.')
    expect(overlay.textContent).not.toContain('대기 중인 Keeper 질문이 없습니다.')

    // 3. Single-user source failure surfaces explicit (조회 실패) in Quick-Peek & FastApprovalStrip
    resetShellStateForTests()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    const failFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      const json = (d: unknown) => new Response(JSON.stringify(d), { status: 200, headers: { 'content-type': 'application/json' } })
      if (url.includes('/api/v1/keepers/tool-approvals')) {
        return new Response(JSON.stringify({ error: 'approval store offline' }), { status: 503, headers: { 'content-type': 'application/json' } })
      }
      if (url.includes('/api/v1/dashboard/shell')) return json({ counts: { keepers: 2, tasks: 4, agents: 1 } })
      if (url.includes('/api/v1/dashboard/scheduled-automation')) return json(EMPTY_ACTIVE_SCHEDULES)
      if (url.includes('/api/v1/keepers/asks')) return json({ asks: [] })
      if (url.includes('/api/v1/dashboard/gate')) return json({ approval_queue: [] })
      if (url.includes('/api/v1/dashboard/planning')) return json({ goals: [] })
      if (url.includes('/api/v1/verification/requests')) return json({ requests: [] })
      return json({})
    })
    vi.stubGlobal('fetch', failFetch)
    await refreshPendingHitl(failFetch as unknown as typeof fetch)
    await act(async () => {
      render(h('div', {}, h(FastApprovalStrip, {}), h(QueueContextOverlayBody, {})), container)
    })
    await act(async () => {
      await new Promise((r) => setTimeout(r, 30))
    })
    expect(container.textContent).toContain('Pending Tool Approvals (조회 실패)')
    expect(container.textContent).toContain('도구 승인 조회 실패')
    expect(container.textContent).toContain('일부 미확인')
    vi.unstubAllGlobals()
  })

  it('marks verification HITL source as partially failed on positive unreadable_total or awaiting_unresolved_total while retaining readable items', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    const json = (d: unknown) =>
      new Response(JSON.stringify(d), { status: 200, headers: { 'content-type': 'application/json' } })

    let verifPayload: Record<string, unknown> = {
      requests: [],
      backlog_error: null,
      unreadable_total: 2,
      awaiting_unresolved_total: 0,
    }
    const verifFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/api/v1/dashboard/shell')) return json({ counts: { keepers: 1, tasks: 2, agents: 1 } })
      if (url.includes('/api/v1/dashboard/scheduled-automation')) {
        return json(EMPTY_ACTIVE_SCHEDULES)
      }
      if (url.includes('/api/v1/verification/requests')) return json(verifPayload)
      for (const [prefix, body] of Object.entries(EMPTY_HITL)) {
        if (url.includes(prefix)) return json(body)
      }
      return json({})
    })
    vi.stubGlobal('fetch', verifFetch)

    // 1. Empty readable list + unreadable_total > 0 -> must surface failure in Quick-Peek instead of hiding as confirmed empty
    await refreshPendingHitl(verifFetch as unknown as typeof fetch)
    expect(pendingVerifications.value).toHaveLength(0)
    expect(effectiveHitlSourceStatus.value.verification).toMatchObject({
      kind: 'failed',
      message: expect.stringContaining('unreadable verification records: 2'),
    })
    expect(historicalIncidents.value.some((i) => i.source === 'verification' && i.detail?.includes('2'))).toBe(true)

    await act(async () => {
      render(h(QueueContextOverlayBody, {}), container)
    })
    await act(async () => {
      await new Promise((r) => setTimeout(r, 20))
    })
    expect(container.textContent).toContain('검증 조회 실패')
    expect(container.textContent).toContain('Awaiting Verifications (조회 실패)')
    expect(container.textContent).toContain('unreadable verification records: 2')

    // 2. Readable awaiting item + awaiting_unresolved_total > 0 -> keep readable item while flagging partial failure
    verifPayload = {
      requests: [{ request_id: 'vr-live', task_id: 't-7', task_title: 'Review patch', submitted_by: 'sangsu' }],
      backlog_error: null,
      unreadable_total: 0,
      awaiting_unresolved_total: 1,
    }
    await act(async () => {
      await refreshPendingHitl(verifFetch as unknown as typeof fetch)
    })
    expect(pendingVerifications.value.map((v) => v.requestId)).toEqual(['vr-live'])
    expect(effectiveHitlSourceStatus.value.verification).toMatchObject({
      kind: 'failed',
      message: expect.stringContaining('unresolved awaiting verification ids: 1'),
    })
    expect(container.textContent).toContain('Awaiting Verifications (1 · 조회 실패)')
    expect(container.textContent).toContain('Review patch')
    expect(container.textContent).toContain('unresolved awaiting verification ids: 1')

    // 3. Zero unreadable & zero unresolved -> clears back to ok
    verifPayload = {
      requests: [],
      backlog_error: null,
      unreadable_total: 0,
      awaiting_unresolved_total: 0,
    }
    await act(async () => {
      await refreshPendingHitl(verifFetch as unknown as typeof fetch)
    })
    expect(effectiveHitlSourceStatus.value.verification).toEqual({ kind: 'ok' })
    expect(container.textContent).not.toContain('Awaiting Verifications')
    vi.unstubAllGlobals()
  })

  describe('Upcoming Schedules', () => {
    beforeEach(() => {
      authSession.value = {
        kind: 'single_user_local',
        mode: 'single_user',
        tokenPresent: true,
        authMethods: AUTH_METHODS,
        workspaceId: 'default',
      }
    })

    afterEach(() => vi.unstubAllGlobals())

    it('reports a missing schedule array as unavailable', async () => {
      vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input)
        if (url.includes('/api/v1/dashboard/scheduled-automation')) {
          return hitlJson({ ...EMPTY_ACTIVE_SCHEDULES, requests: undefined })
        }
        return hitlJson(Object.entries(EMPTY_HITL).find(([path]) => url.includes(path))?.[1] ?? {})
      }))

      await act(async () => { render(h(QueueContextOverlayBody, {}), container) })

      await waitFor(() => expect(container.textContent).toContain('예약 조회 실패'))
      expect(container.textContent).not.toContain('Upcoming Schedules (0)')
      expect(container.textContent).not.toContain('활성 예약 자동화가 없습니다.')
    })

    it('shares the calendar read and retains its last sample through an unavailable response', async () => {
      const reads: Array<(response: Response) => void> = []
      vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input)
        if (url.includes('/api/v1/dashboard/scheduled-automation?active_only=true')) {
          return new Promise<Response>(resolve => { reads.push(resolve) })
        }
        return hitlJson(Object.entries(EMPTY_HITL).find(([path]) => url.includes(path))?.[1] ?? {})
      }))

      const stopCalendar = subscribeActiveSchedulesRefresh()
      try {
        await act(async () => { render(h(QueueContextOverlayBody, {}), container) })
        await waitFor(() => expect(reads).toHaveLength(1))
        expect(container.textContent).toContain('예약 불러오는 중')
        await act(async () => reads[0]!(hitlJson({
          ...EMPTY_ACTIVE_SCHEDULES,
          request_count: 1,
          requests: [{ schedule_id: 'sc-2', status: 'scheduled', payload_summary: 'Patrol sample' }],
        })))
        await waitFor(() => expect(container.textContent).toContain('Patrol sample'))
        expect(container.textContent).toContain('Upcoming Schedules (1)')

        await act(async () => publishDashboardObservationChange({ topic: 'scheduled_automation' }))
        await waitFor(() => expect(reads).toHaveLength(2))
        expect(container.textContent).toContain('예약 갱신 중')
        expect(container.textContent).toContain('Patrol sample')
        await act(async () => reads[1]!(hitlJson({
          status: 'unknown',
          schedule_store_known: false,
          schedule_store_read_error: 'ledger offline',
        })))
        await waitFor(() => expect(container.textContent).toContain('ledger offline'))
        expect(container.textContent).toContain('Patrol sample')
        expect(container.textContent).toContain('마지막 확인')
        expect(container.querySelector('time')?.getAttribute('datetime')).toBeTruthy()

        await act(async () => publishDashboardObservationChange({ topic: 'scheduled_automation' }))
        await waitFor(() => expect(reads).toHaveLength(3))
        await act(async () => reads[2]!(hitlJson(EMPTY_ACTIVE_SCHEDULES)))
        await waitFor(() => expect(container.textContent).toContain('활성 예약 자동화가 없습니다.'))
        expect(container.textContent).toContain('Upcoming Schedules (0)')
        expect(container.textContent).not.toContain('Patrol sample')
        expect(container.textContent).not.toContain('ledger offline')
      } finally { stopCalendar() }
    })

    it('releases the previous workspace sample and request before reading the selected route', async () => {
      const reads: Array<{ url: string; signal: AbortSignal | null; finish: (response: Response) => void }> = []
      registerWorkspaceTargets([
        { id: 'alpha', label: 'Alpha', baseUrl: '/ws/alpha' },
        { id: 'beta', label: 'Beta', baseUrl: '/ws/beta' },
      ])
      vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input)
        if (url.includes('/api/v1/dashboard/scheduled-automation?active_only=true')) {
          return new Promise<Response>(finish => { reads.push({ url, signal: init?.signal ?? null, finish }) })
        }
        return hitlJson(Object.entries(EMPTY_HITL).find(([path]) => url.includes(path))?.[1] ?? {})
      }))
      const page = (id: string) => hitlJson({
        ...EMPTY_ACTIVE_SCHEDULES, request_count: 1,
        requests: [{ schedule_id: id, payload_summary: id, status: 'scheduled' }],
      })
      await act(async () => { render(h(QueueContextOverlayBody, {}), container) })
      await waitFor(() => expect(reads).toHaveLength(1))
      expect(reads[0]?.url).toBe('/ws/alpha/api/v1/dashboard/scheduled-automation?active_only=true')
      await act(async () => reads[0]!.finish(page('Alpha patrol')))
      await waitFor(() => expect(container.textContent).toContain('Alpha patrol'))

      await act(async () => publishDashboardObservationChange({ topic: 'scheduled_automation' }))
      await waitFor(() => expect(reads).toHaveLength(2))
      await act(async () => { selectWorkspace('beta') })
      expect(container.textContent).not.toContain('Alpha patrol')
      expect(reads[1]?.signal?.aborted).toBe(true)
      await waitFor(() => expect(reads).toHaveLength(3))
      expect(reads[2]?.url).toBe('/ws/beta/api/v1/dashboard/scheduled-automation?active_only=true')
      await act(async () => reads[2]!.finish(page('Beta patrol')))
      await waitFor(() => expect(container.textContent).toContain('Beta patrol'))
      await act(async () => reads[1]!.finish(page('Alpha late patrol')))
      expect(container.textContent).toContain('Beta patrol')
      expect(container.textContent).not.toContain('Alpha late patrol')
    })
  })
})
