// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { act, fireEvent } from '@testing-library/preact'
import {
  activeWorkspaceId,
  authSession,
  bumpSessionEpoch,
  registerWorkspaceTargets,
  resetAuthStateForTests,
  sessionEpoch,
} from '../core/auth'
import {
  observerConnected,
  resetObserverStateForTests,
  viewProvenance,
} from '../core/observer'
import { resetTimeWindowForTests, timeWindow } from '../core/time-window'
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

  it('FastApprovalStrip renders 0px when clear, wraps mutations in TargetLockedAction, and locks on sessionEpoch drift', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }

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
          status: 'ok',
          schedule_store_known: true,
          request_count: 1,
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
})
