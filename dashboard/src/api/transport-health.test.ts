import { describe, expect, it } from 'vitest'
import { Option, err, ok } from '../lib/result'
import { DashboardTransportError } from './effect-http'
import {
  fetchTransportHealth,
  TransportHealthSchemaDriftError,
} from './transport-health'

const initializingWire = {
  status: 'initializing',
  generated_at: '2026-08-12T00:00:00Z',
  message: 'Transport health data is warming up.',
  projection_diagnostics: {
    source: 'cached_surface',
    cache_state: 'initializing',
    last_success_at: null,
    last_attempt_at: null,
    last_error_at: null,
    stale_reason: null,
    stale_age_ms: null,
  },
} as const

describe('fetchTransportHealth', () => {
  it('decodes the unknown HTTP payload before exposing a domain value', async () => {
    const res = await fetchTransportHealth({
      getUnknown: async () => ok(initializingWire),
    })

    expect(res.ok).toBe(true)
    if (!res.ok) return
    expect('status' in res.value && res.value.status).toBe('initializing')
    expect(Option.isNone(res.value.projection_diagnostics.last_success_at)).toBe(true)
  })

  it('preserves a transport failure as a typed error', async () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/dashboard/transport-health',
      message: 'network unavailable',
      cause: new Error('network unavailable'),
    })
    const res = await fetchTransportHealth({
      getUnknown: async () => err(transportError),
    })

    expect(res.ok).toBe(false)
    if (res.ok) return
    expect(res.error).toBe(transportError)
  })

  it('maps an invalid HTTP payload to schema drift', async () => {
    const res = await fetchTransportHealth({
      getUnknown: async () => ok({ status: 'ready' }),
    })

    expect(res.ok).toBe(false)
    if (res.ok) return
    expect(res.error).toBeInstanceOf(TransportHealthSchemaDriftError)
  })
})
