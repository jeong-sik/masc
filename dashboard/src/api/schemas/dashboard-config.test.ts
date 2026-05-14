import { describe, expect, it } from 'vitest'
import {
  DashboardConfigSchemaDriftError,
  parseDashboardConfigResponse,
} from './dashboard-config'

const validDashboardConfig = {
  generated_at: '2026-05-12T00:00:00Z',
  server: {
    version: '0.19.17',
    git_commit: null,
    ocaml_version: '5.4.0',
    uptime_seconds: 42,
    pid: 12345,
  },
  categories: {
    dashboard: [
      {
        env: 'MASC_DASHBOARD_CTX_PREPARING',
        description: 'Warn threshold',
        value: '0.72',
        default: '0.70',
        source: 'env',
        source_detail: 'process env',
        provenance: {
          kind: 'runtime',
          detail: 'derived at boot',
          derived_from: ['MASC_DASHBOARD_CTX_PREPARING'],
        },
        sensitive: false,
      },
    ],
  },
}

describe('dashboard config schema', () => {
  it('parses valid dashboard config payloads', () => {
    const parsed = parseDashboardConfigResponse(validDashboardConfig)

    expect(parsed.server.version).toBe('0.19.17')
    expect(parsed.categories.dashboard?.[0]?.env).toBe('MASC_DASHBOARD_CTX_PREPARING')
  })

  it('throws typed drift errors when required server fields are missing', () => {
    const drifted = {
      ...validDashboardConfig,
      server: {
        version: '0.19.17',
        git_commit: null,
        ocaml_version: '5.4.0',
        uptime_seconds: 42,
      },
    }

    expect(() => parseDashboardConfigResponse(drifted)).toThrow(DashboardConfigSchemaDriftError)
  })
})
