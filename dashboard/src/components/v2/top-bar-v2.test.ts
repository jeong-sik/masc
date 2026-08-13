import { h } from 'preact'
import { cleanup, fireEvent, render } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { LIVE_OVERVIEW_COMPOSITE_HEALTH } from '../../testing/dashboard-composite-health-fixture'

const mocks = vi.hoisted(() => ({
  navigate: vi.fn(),
  keepers: { value: [] as unknown[] },
  dashboardFullHealth: { value: null as unknown },
  shellRuntimeResolution: {
    value: null as unknown,
  },
}))

vi.mock('../../store', () => ({
  executionLoaded: { value: true },
  keepers: mocks.keepers,
  shellCounts: { value: null },
  shellRuntimeResolution: mocks.shellRuntimeResolution,
  staleKeepers: { value: new Set<string>() },
}))

vi.mock('../gate-signals', () => ({
  gateData: {
    value: {
      approval_queue_state: { state: 'ready' },
      approval_queue: [],
    },
  },
}))

vi.mock('../dashboard-full-health-state', () => ({
  dashboardFullHealth: mocks.dashboardFullHealth,
  subscribeDashboardFullHealthRefresh: () => () => {},
}))

vi.mock('../../router', () => ({
  navigate: mocks.navigate,
  route: { value: { tab: 'overview', params: {} } },
}))

vi.mock('../../keeper-state', () => ({ activeKeeperName: { value: '' } }))
vi.mock('../dashboard-shell', () => ({
  ConnectionStatus: () => null,
  ErrorCounterBadge: () => null,
  BuildIdentityBadge: () => null,
}))
vi.mock('../auth-status', () => ({ AuthStatus: () => null }))
vi.mock('../emergency-stop-control', () => ({ EmergencyStopControl: () => null }))
vi.mock('../transport-beacon', () => ({ TransportBeacon: () => null }))
vi.mock('../copilot-dock', () => ({ CopilotDockTopBarButton: () => null }))
vi.mock('../tweaks-panel', () => ({ TweaksPanelToggle: () => null }))
vi.mock('./primitives-v2', () => ({ StatusDot: () => null }))
vi.mock('./nav-rail-v2', () => ({ surfaceLabel: () => 'Overview' }))

import { AttentionIndicatorV2 } from './top-bar-v2'

describe('AttentionIndicatorV2 composite health interaction', () => {
  afterEach(() => {
    cleanup()
    mocks.navigate.mockReset()
    mocks.shellRuntimeResolution.value = null
    mocks.dashboardFullHealth.value = null
  })

  it('opens the degraded backend health rows and drills into fleet health', () => {
    mocks.dashboardFullHealth.value = LIVE_OVERVIEW_COMPOSITE_HEALTH
    const { getByRole, getByText } = render(h(AttentionIndicatorV2, null))

    const attentionButton = getByRole('button', { name: /주의 1/ })
    expect(attentionButton.textContent).not.toContain('정상')

    fireEvent.click(attentionButton)
    const fleetRow = getByText('Runtime health degraded').closest('button')
    expect(fleetRow?.title).toContain('keeper_fleet_safety')
    expect(fleetRow?.title).toContain('keeper_reaction_ledger')

    fireEvent.click(fleetRow!)
    expect(mocks.navigate).toHaveBeenCalledWith('monitoring', { section: 'fleet-health' })
  })
})
