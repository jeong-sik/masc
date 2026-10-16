// @vitest-environment happy-dom
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { waitFor } from '@testing-library/preact'

vi.mock('../../lib/auto-refresh', () => ({
  setupVisibleAutoRefresh: vi.fn(() => vi.fn()),
}))

import { agents, executionLoaded, keepers } from '../../store'
import { navigate, route } from '../../router'
import { AgentsUnified } from '../agents-unified'
import { gateResource } from '../gate-signals'
import { dashboardFullHealthResource } from '../dashboard-full-health-state'
import { AttentionIndicatorV2 } from './top-bar-v2'
import type { DashboardGateResponse } from '../../types'

function healthResponse(operatorActionRequired: boolean, overallStatus = 'degraded') {
  return {
    overall_status: overallStatus,
    operator_action_required: operatorActionRequired,
    operator_action_reasons: operatorActionRequired ? ['keeper_event_queue'] : [],
    full_health_snapshot: {
      status: 'ready',
      stale_reason: null,
      last_good_available: true,
      component_timed_out: false,
    },
  }
}

const readyGate: DashboardGateResponse = {
  approval_queue: [],
  approval_queue_state: { state: 'ready' },
  recent_resolved: [],
  recent_resolved_page: null,
  recent_resolved_state: { state: 'ready' },
  approval_rules: [],
  approval_rules_state: { state: 'ready' },
  keeper_modes: [],
  keeper_modes_state: { state: 'ready' },
  keeper_exact_lanes: [],
  keeper_exact_lanes_state: { state: 'ready' },
  hitl: null,
}

describe('AttentionIndicatorV2 backend health', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    gateResource.reset(readyGate)
    dashboardFullHealthResource.reset()
    keepers.value = []
    agents.value = []
    executionLoaded.value = false
    navigate('overview')
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    gateResource.reset()
    dashboardFullHealthResource.reset()
    vi.unstubAllGlobals()
  })

  it('counts an explicit backend action requirement exactly once', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      JSON.stringify(healthResponse(true)),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )))

    await act(async () => {
      render(html`<${AttentionIndicatorV2} />`, container)
    })

    await waitFor(() => {
      expect(container.querySelector('.v2-statchip.attn')?.textContent).toContain('주의 1')
    })
    ;(container.querySelector('.v2-statchip.attn') as HTMLButtonElement).click()
    await waitFor(() => {
      expect(container.querySelector('.attn-row')?.textContent).toContain('Runtime health degraded')
      expect(container.querySelector('.attn-row')?.textContent).toContain('1')
    })
  })

  it('shows a non-action degraded verdict without counting operator work', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      JSON.stringify(healthResponse(false)),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )))

    await act(async () => {
      render(html`<${AttentionIndicatorV2} />`, container)
    })

    await waitFor(() => {
      const chip = container.querySelector('.v2-statchip.attn')
      expect(chip?.textContent).toContain('Runtime health degraded')
      expect(chip?.textContent).not.toContain('주의 1')
    })
  })

  it('keeps the chip bad when a non-action bad health status accompanies counted work', async () => {
    keepers.value = [{ name: 'sangsu', status: 'running', needs_attention: true }]
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      JSON.stringify(healthResponse(false, 'error')),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )))

    await act(async () => {
      render(html`<${AttentionIndicatorV2} />`, container)
    })

    await waitFor(() => {
      const chip = container.querySelector('.v2-statchip.attn')
      expect(chip?.classList.contains('bad')).toBe(true)
      expect(chip?.textContent).toContain('주의 1')
    })
    ;(container.querySelector('.v2-statchip.attn') as HTMLButtonElement).click()
    await waitFor(() => {
      expect(container.textContent).toContain('Runtime health error')
    })
  })

  it('keeps a non-ready Gate title visible on the collapsed chip', async () => {
    gateResource.reset({
      ...readyGate,
      approval_queue: null,
      approval_queue_state: {
        state: 'observation_error',
        code: 'observation_failed',
        title: 'Gate observation unavailable',
        operator_detail: 'Gate refresh failed',
        severity: 'bad',
        icon: '!',
      },
    })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      JSON.stringify(healthResponse(false)),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )))

    await act(async () => {
      render(html`<${AttentionIndicatorV2} />`, container)
    })

    await waitFor(() => {
      const chip = container.querySelector('.v2-statchip.attn')
      expect(chip?.textContent).toContain('! Gate observation unavailable')
      expect(chip?.textContent).not.toContain('주의 ?')
      expect(chip?.classList.contains('bad')).toBe(true)
      expect(chip?.getAttribute('title')).toBe('Gate refresh failed')
    })
  })

  it('opens the matching Keeper roster from each attention cause and lets the operator clear it', async () => {
    keepers.value = [
      { name: 'needs-input', status: 'offline', needs_attention: true, registered: false, keepalive_running: false },
      { name: 'failed-keeper', status: 'offline', lifecycle_phase: 'Crashed', registered: false, keepalive_running: false },
      { name: 'inactive-keeper', status: 'offline', registered: false, keepalive_running: false },
      { name: 'healthy-keeper', status: 'running' },
    ]
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      JSON.stringify(healthResponse(false, 'ok')),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )))
    await act(async () => {
      render(html`<${AttentionIndicatorV2} /><${AgentsUnified} />`, container)
    })
    const chooseCause = async (label: string) => {
      await act(async () => { container.querySelector<HTMLButtonElement>('.attn-wrap .v2-statchip')?.click() })
      const item = Array.from(container.querySelectorAll<HTMLButtonElement>('.attn-row'))
        .find(button => button.textContent?.includes(label))
      expect(item).toBeDefined()
      await act(async () => { item?.click() })
    }
    const rosterNames = () => Array.from(container.querySelectorAll('.fl-roster .fl-name b')).map(node => node.textContent)

    expect(rosterNames()).toEqual(['healthy-keeper'])
    await chooseCause('주의')
    expect(route.value.params).toMatchObject({ section: 'agents', view: 'keepers', filter: 'attention' })
    expect(rosterNames()).toEqual(['needs-input'])
    expect(container.querySelector('[aria-haspopup="menu"]')?.getAttribute('aria-expanded')).toBe('false')
    await chooseCause('실패한 Keeper')
    expect(route.value.params.filter).toBe('failures')
    expect(rosterNames()).toEqual(['failed-keeper'])
    await act(async () => { container.querySelector<HTMLButtonElement>('.fl-route-filter button')?.click() })
    expect(route.value.params.filter).toBeUndefined()
    expect(rosterNames()).toEqual(['healthy-keeper'])
  })

  it('opens attention causes from the keyboard and restores focus on dismissal', async () => {
    keepers.value = [
      { name: 'needs-input', status: 'running', needs_attention: true },
      { name: 'failed-keeper', status: 'offline', lifecycle_phase: 'Crashed' },
    ]
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      JSON.stringify(healthResponse(false, 'ok')),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )))
    await act(async () => { render(html`<${AttentionIndicatorV2} />`, container) })
    const trigger = container.querySelector<HTMLButtonElement>('.attn-wrap >button')!
    await act(async () => { trigger.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true })) })
    const items = container.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')
    expect(trigger.getAttribute('aria-expanded')).toBe('true')
    expect(document.activeElement).toBe(items[0])
    await act(async () => { items[0]?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true })) })
    expect(document.activeElement).toBe(items[1])
    await act(async () => { items[1]?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })) })
    expect(trigger.getAttribute('aria-expanded')).toBe('false')
    expect(document.activeElement).toBe(trigger)
  })
})
