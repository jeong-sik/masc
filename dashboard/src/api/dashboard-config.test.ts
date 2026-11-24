import { describe, expect, it } from 'vitest'
import { err, ok } from '../lib/result'
import { DashboardTransportError } from './effect-http'
import {
  DashboardConfigSchemaDriftError,
  fetchDashboardConfig,
} from './dashboard-config'

const currentWire = {
  generated_at: '2026-08-12T00:00:00Z',
  server: {
    version: '0.42.0',
    git_commit: null,
    ocaml_version: '5.4.0',
    uptime_seconds: 10,
    pid: 42,
  },
  categories: {},
} as const

describe('fetchDashboardConfig', () => {
  it('fetches and decodes unknown config data at the typed boundary', async () => {
    const res = await fetchDashboardConfig({
      getUnknown: async path => {
        expect(path).toBe('/api/v1/dashboard/config')
        return ok(currentWire)
      },
    })

    expect(res.ok).toBe(true)
    if (!res.ok) return
    expect(res.value.server.version).toBe('0.42.0')
  })

  it('preserves transport failures as typed values', async () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/dashboard/config',
      message: 'offline',
      cause: new Error('offline'),
    })
    const res = await fetchDashboardConfig({ getUnknown: async () => err(transportError) })

    expect(res.ok).toBe(false)
    if (res.ok) return
    expect(res.error).toBe(transportError)
  })

  it('maps malformed payloads to config drift', async () => {
    const res = await fetchDashboardConfig({
      getUnknown: async () => ok({ generated_at: 'now' }),
    })

    expect(res.ok).toBe(false)
    if (res.ok) return
    expect(res.error).toBeInstanceOf(DashboardConfigSchemaDriftError)
  })
})
