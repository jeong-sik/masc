import { describe, expect, it } from 'vitest'
import { err, ok } from '../lib/result'
import { DashboardTransportError } from './effect-http'
import {
  fetchGateKeepers,
  GateKeepersSchemaDriftError,
} from './gate-keepers'

const currentWire = {
  candle: { status: 'off' },
  count: 1,
  keepers: [{
    runtime_class: 'keeper',
    candle_balance_milli: null,
    candle_account_revision: null,
    portrait: { state: 'ready', equipment: { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } },
    name: 'planner',
    meta: {
      name: 'planner',
      sandbox_profile: 'docker',
      trace_id: 'trace-planner',
      created_at: '2026-08-12T00:00:00Z',
      updated_at: '2026-08-12T00:01:00Z',
    },
    status: 'active',
    phase: 'running',
    health: 'healthy',
    paused: false,
    next_action: 'direct_message',
    last_failure: null,
    runtime_lane_observation: null,
    runtime_blocker_summary: null,
    runtime_blocker_signature: null,
    keepalive_running: true,
    activation_mode: 'on_demand',
    runtime_id: 'runtime-planner',
    created_at: '2026-08-12T00:00:00Z',
    updated_at: '2026-08-12T00:01:00Z',
    context_ratio: null,
    context_tokens: null,
    context_max: null,
    context_source: null,
    context_provenance: 'unavailable',
    estimated_context_ratio: null,
    context_metrics_unavailable: { kind: 'not_observed', reason: 'context_measurement_missing' },
    context_metrics_unavailable_reason: 'context_measurement_missing',
    context: {
      source: null,
      context_ratio: null,
      context_tokens: null,
      context_max: null,
      provenance: 'unavailable',
      estimated_context_ratio: null,
      metrics_unavailable: { kind: 'not_observed', reason: 'context_measurement_missing' },
      metrics_unavailable_reason: 'context_measurement_missing',
    },
  }],
  total: 1,
  limit: 200,
  truncated: false,
} as const

describe('fetchGateKeepers', () => {
  it('fetches and decodes unknown data at the typed endpoint boundary', async () => {
    const res = await fetchGateKeepers({
      getUnknown: async path => {
        expect(path).toBe('/api/v1/gate/keepers?detailed=true')
        return ok(currentWire)
      },
    })

    expect(res.ok).toBe(true)
    if (!res.ok) return
    expect(res.value.keepers[0]?.name).toBe('planner')
    expect(res.value.listing).toEqual({ total: 1, limit: 200, truncated: false })
  })

  it('does not pin a limit — the route bounds itself and reports the bound', async () => {
    await fetchGateKeepers({
      getUnknown: async path => {
        expect(path).not.toContain('limit=')
        return ok(currentWire)
      },
    })
  })

  it('carries the truncation verdict through to the product value', async () => {
    const truncatedWire = { ...currentWire, total: 129, limit: 50, truncated: true }
    const res = await fetchGateKeepers({
      getUnknown: async () => ok(truncatedWire),
    })

    expect(res.ok).toBe(true)
    if (!res.ok) return
    expect(res.value.listing.truncated).toBe(true)
    expect(res.value.listing.total).toBe(129)
    expect(res.value.keepers.length).toBe(1)
  })

  it('rejects a response that omits the listing fields', async () => {
    const { total: _total, ...withoutTotal } = currentWire
    const res = await fetchGateKeepers({ getUnknown: async () => ok(withoutTotal) })

    expect(res.ok).toBe(false)
    if (res.ok) return
    expect(res.error).toBeInstanceOf(GateKeepersSchemaDriftError)
  })

  it('preserves transport failures as typed values', async () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/gate/keepers?detailed=true',
      message: 'offline',
      cause: new Error('offline'),
    })
    const res = await fetchGateKeepers({ getUnknown: async () => err(transportError) })

    expect(res.ok).toBe(false)
    if (res.ok) return
    expect(res.error).toBe(transportError)
  })

  it('preserves schema drift as a typed endpoint error', async () => {
    const res = await fetchGateKeepers({
      getUnknown: async () => ok({ candle: { status: 'off' }, count: 1, keepers: [] }),
    })

    expect(res.ok).toBe(false)
    if (res.ok) return
    expect(res.error).toBeInstanceOf(GateKeepersSchemaDriftError)
  })
})
