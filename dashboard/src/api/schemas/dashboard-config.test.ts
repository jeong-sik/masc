import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  DashboardConfigSchemaDriftError,
  decodeDashboardConfig,
} from './dashboard-config'

function currentWire(value: string | null = '0.72') {
  return {
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
          value,
          default: '0.70',
          source: 'env',
          source_detail: 'environment variable MASC_DASHBOARD_CTX_PREPARING',
          provenance: {
            kind: 'env',
            detail: 'environment variable MASC_DASHBOARD_CTX_PREPARING',
            env: 'MASC_DASHBOARD_CTX_PREPARING',
            raw_source: 'environment',
            raw_env_present: true,
            raw_env_blank: false,
            default: '0.70',
            sensitive: false,
            value_redacted: false,
          },
          sensitive: false,
        },
      ],
    },
  }
}

function expectDrift(value: unknown): DashboardConfigSchemaDriftError {
  const error = Effect.runSync(Effect.flip(decodeDashboardConfig(value)))
  expect(error).toBeInstanceOf(DashboardConfigSchemaDriftError)
  expect(error.message).toContain('dashboard-config schema drift')
  return error
}

describe('decodeDashboardConfig', () => {
  it('strictly decodes current wire data into the config domain', () => {
    const parsed = Effect.runSync(decodeDashboardConfig(currentWire()))
    const entry = parsed.categories.dashboard?.[0]

    expect(parsed.server).toEqual({
      version: '0.19.17',
      ocamlVersion: '5.4.0',
      uptimeSeconds: 42,
      pid: 12345,
    })
    expect(entry).toEqual({
      env: 'MASC_DASHBOARD_CTX_PREPARING',
      description: 'Warn threshold',
      displayValue: '0.72',
      defaultValue: '0.70',
      source: 'env',
      sourceDetail: 'environment variable MASC_DASHBOARD_CTX_PREPARING',
      sensitive: false,
    })
  })

  it('resolves a missing wire value to its product default once', () => {
    const parsed = Effect.runSync(decodeDashboardConfig(currentWire(null)))
    expect(parsed.categories.dashboard?.[0]?.displayValue).toBe('0.70')
  })

  it.each([
    ['missing required server field', (() => {
      const wire = currentWire()
      const { pid: _pid, ...server } = wire.server
      return { ...wire, server }
    })()],
    ['top-level excess property', { ...currentWire(), legacy: true }],
    ['nested excess property', (() => {
      const wire = currentWire()
      return {
        ...wire,
        categories: {
          dashboard: [{ ...wire.categories.dashboard[0], legacy_value: 'x' }],
        },
      }
    })()],
    ['unknown source variant', (() => {
      const wire = currentWire()
      return {
        ...wire,
        categories: {
          dashboard: [{ ...wire.categories.dashboard[0], source: 'file' }],
        },
      }
    })()],
  ])('rejects %s', (_name, value) => {
    expectDrift(value)
  })

  it('rejects provenance that disagrees with the entry', () => {
    const wire = currentWire()
    const entry = wire.categories.dashboard[0]
    if (entry === undefined) throw new Error('dashboard config fixture missing')
    const error = expectDrift({
      ...wire,
      categories: {
        dashboard: [{
          ...entry,
          provenance: { ...entry.provenance, default: '0.65' },
        }],
      },
    })

    expect(error.message).toContain('provenance.default')
  })
})
