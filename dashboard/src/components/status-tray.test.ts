import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import type { Keeper, Task } from '../types'
import { dashboardWsConnected, dashboardWsEventCount60s, dashboardWsLastError, dashboardWsLastEventAt, dashboardWsReady, _resetDashboardWsCounterForTests } from '../dashboard-ws-state'
import { route } from '../router'
import { keepers, keeperHeartbeats, tasks } from '../store'
import { connected, journal, lastDisconnectedAt, reconnectCount } from '../sse'
import { errors } from './common/error-notification-state'
import { DashboardStatusTray, summarizeStatusTray } from './status-tray'

vi.mock('./common/time-ago', () => ({
  TimeAgo: ({ timestamp }: { timestamp: string | number }) => h('span', {}, String(timestamp)),
}))

const NOW = 1_000_000_000_000

function keeper(name: string, overrides: Partial<Keeper> = {}): Keeper {
  return {
    name,
    status: 'active',
    ...overrides,
  }
}

function task(id: string, status: Task['status']): Task {
  return {
    id,
    title: id,
    status,
  }
}

describe('summarizeStatusTray', () => {
  it('marks WS-only transport red when the socket is not ready', () => {
    const summary = summarizeStatusTray({
      wsOnly: true,
      sseConnected: false,
      wsConnected: false,
      wsReady: false,
      wsLastEventAt: 0,
      wsEventCount60s: 0,
      wsLastError: 'socket closed',
      reconnectCount: 0,
      lastDisconnectedAt: 0,
      keepers: [],
      staleKeeperNames: new Set(),
      tasks: [],
      journalEntries: [],
      unacknowledgedErrors: 0,
      now: NOW,
    })

    expect(summary.items.transport.tone).toBe('err')
    expect(summary.items.transport.value).toBe('closed')
    expect(summary.items.transport.detail).toContain('socket closed')
  })

  it('rolls stale keeper, verification, and error counts into tray items', () => {
    const summary = summarizeStatusTray({
      wsOnly: false,
      sseConnected: true,
      wsConnected: true,
      wsReady: true,
      wsLastEventAt: NOW - 1000,
      wsEventCount60s: 4,
      wsLastError: null,
      reconnectCount: 1,
      lastDisconnectedAt: 0,
      keepers: [
        keeper('alpha'),
        keeper('beta', { needs_attention: true }),
      ],
      staleKeeperNames: new Set(['alpha']),
      tasks: [
        task('t1', 'awaiting_verification'),
        task('t2', 'done'),
      ],
      journalEntries: [],
      unacknowledgedErrors: 2,
      now: NOW,
    })

    expect(summary.items.transport.tone).toBe('ok')
    expect(summary.items.fleet.tone).toBe('warn')
    expect(summary.items.fleet.value).toBe('1/2')
    expect(summary.items.attention.tone).toBe('err')
    expect(summary.items.attention.value).toBe('4')
    expect(summary.counts).toMatchObject({
      staleKeepers: 1,
      keeperAttention: 1,
      pendingVerificationTasks: 1,
      unacknowledgedErrors: 2,
      reconnectCount: 1,
      wsEventCount60s: 4,
    })
  })

  it('uses the first journal entry for activity state from newest-first snapshots', () => {
    const summary = summarizeStatusTray({
      wsOnly: false,
      sseConnected: true,
      wsConnected: false,
      wsReady: false,
      wsLastEventAt: 0,
      wsEventCount60s: 0,
      wsLastError: null,
      reconnectCount: 0,
      lastDisconnectedAt: 0,
      keepers: [],
      staleKeeperNames: new Set(),
      tasks: [],
      journalEntries: [
        { agent: 'new', text: 'new warning', timestamp: NOW - 1000, kind: 'keepers', severity: 'warn' },
        { agent: 'old', text: 'old entry', timestamp: NOW - 20_000, kind: 'system' },
      ],
      unacknowledgedErrors: 0,
      now: NOW,
    })

    expect(summary.items.activity.tone).toBe('warn')
    expect(summary.items.activity.value).toBe('keepers')
    expect(summary.latestJournalEntries[0]?.agent).toBe('new')
  })

  it('preserves journal snapshot order instead of resorting by timestamp', () => {
    const summary = summarizeStatusTray({
      wsOnly: false,
      sseConnected: true,
      wsConnected: false,
      wsReady: false,
      wsLastEventAt: 0,
      wsEventCount60s: 0,
      wsLastError: null,
      reconnectCount: 0,
      lastDisconnectedAt: 0,
      keepers: [],
      staleKeeperNames: new Set(),
      tasks: [],
      journalEntries: [
        { agent: 'first', text: 'ring buffer first entry', timestamp: NOW - 20_000, kind: 'system' },
        { agent: 'second', text: 'higher timestamp but older snapshot position', timestamp: NOW, kind: 'keepers', severity: 'warn' },
      ],
      unacknowledgedErrors: 0,
      now: NOW,
    })

    expect(summary.latestJournalEntries.map(entry => entry.agent)).toEqual(['first', 'second'])
    expect(summary.items.activity.value).toBe('system')
  })
})

describe('DashboardStatusTray', () => {
  beforeEach(() => {
    route.value = { tab: 'overview', params: {}, postId: null }
    connected.value = true
    reconnectCount.value = 0
    lastDisconnectedAt.value = 0
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
    dashboardWsLastError.value = null
    _resetDashboardWsCounterForTests()
    keepers.value = [keeper('alpha')]
    keeperHeartbeats.value = new Map()
    tasks.value = []
    journal.value = [
      { agent: 'alpha', text: 'keeper completed a pass', timestamp: NOW, kind: 'keepers' },
    ]
    errors.value = []
  })

  afterEach(() => {
    cleanup()
    keepers.value = []
    keeperHeartbeats.value = new Map()
    tasks.value = []
    journal.value = []
    errors.value = []
    connected.value = false
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
    dashboardWsLastEventAt.value = 0
    dashboardWsEventCount60s.value = 0
    vi.clearAllMocks()
  })

  it('opens the activity popover and closes it with Escape', () => {
    render(h(DashboardStatusTray, { sideRailCollapsed: false }))

    expect(screen.getByTestId('dashboard-status-tray')).toBeInTheDocument()
    expect(screen.queryByTestId('dashboard-status-tray-popover')).not.toBeInTheDocument()

    fireEvent.click(screen.getByTestId('dashboard-status-tray-activity'))

    expect(screen.getByTestId('dashboard-status-tray-activity')).toHaveAttribute('aria-haspopup', 'dialog')
    expect(screen.getByTestId('dashboard-status-tray-popover')).toBeInTheDocument()
    expect(screen.getAllByText('keeper completed a pass')).toHaveLength(2)

    fireEvent.keyDown(document, { key: 'Escape' })

    expect(screen.queryByTestId('dashboard-status-tray-popover')).not.toBeInTheDocument()
  })

  it('closes the popover on outside click', () => {
    render(h(DashboardStatusTray, { sideRailCollapsed: false }))

    fireEvent.click(screen.getByTestId('dashboard-status-tray-activity'))
    expect(screen.getByTestId('dashboard-status-tray-popover')).toBeInTheDocument()

    fireEvent.mouseDown(document.body)

    expect(screen.queryByTestId('dashboard-status-tray-popover')).not.toBeInTheDocument()
  })
})
