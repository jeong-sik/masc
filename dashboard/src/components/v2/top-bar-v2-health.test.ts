// @vitest-environment happy-dom
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { waitFor } from '@testing-library/preact'

vi.mock('../../lib/auto-refresh', () => ({
  setupVisibleAutoRefresh: vi.fn(() => vi.fn()),
}))

import { keepers } from '../../store'
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
  hitl: null,
}

describe('AttentionIndicatorV2 backend health', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    keepers.value = []
    gateResource.reset(readyGate)
    dashboardFullHealthResource.reset()
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
})
