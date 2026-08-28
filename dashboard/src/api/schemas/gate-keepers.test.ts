import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  GateKeepersSchemaDriftError,
  decodeGateKeepers,
} from './gate-keepers'

// Keep this fixture keyed to keeper_list_row_json in
// lib/keeper/keeper_tool_surface_ops.ml — the schema is strict both ways,
// so a fixture that drifts from the producer only validates itself.
function keeperWire(name = 'planner') {
  return {
    runtime_class: 'keeper',
    name,
    meta: {
      name,
      trace_id: `trace-${name}`,
      created_at: '2026-08-12T00:00:00Z',
      updated_at: '2026-08-12T00:01:00Z',
    },
    status: 'running',
    phase: 'active',
    health: 'healthy',
    paused: false,
    next_action: null,
    keepalive_running: true,
    autoboot_enabled: true,
    proactive_enabled: false,
    runtime_id: `runtime-${name}`,
    created_at: '2026-08-12T00:00:00Z',
    updated_at: '2026-08-12T00:01:00Z',
  }
}

function issueWire(name = 'broken') {
  return {
    status: 'error',
    runtime_class: 'keeper',
    name,
    keepalive_running: false,
    effective_meta_error: {
      keeper: name,
      message: 'invalid keeper config',
      terminal_reason: 'effective_meta_read_failed',
      severity: 'error',
      operator_action_required: true,
      next_action: 'fix_keeper_toml_or_keeper_instructions',
    },
    meta: null,
    created_at: null,
    updated_at: null,
  }
}

function expectDrift(value: unknown): GateKeepersSchemaDriftError {
  const error = Effect.runSync(Effect.flip(decodeGateKeepers(value)))
  expect(error).toBeInstanceOf(GateKeepersSchemaDriftError)
  expect(error.message).toContain('gate-keepers schema drift')
  return error
}

// The listing half of the envelope. Present on every valid fixture so a
// drift assertion below fails for the reason it names, not for a missing
// field. masc#29077.
const listingWire = (total: number) => ({ total, limit: 200, truncated: false })

describe('decodeGateKeepers', () => {
  it('decodes the current detailed wire shape into concrete product values', () => {
    const data = Effect.runSync(decodeGateKeepers({
      count: 1,
      keepers: [keeperWire()],
      ...listingWire(1),
    }))

    expect(data).toEqual({
      keepers: [{
        name: 'planner',
        status: 'running',
      }],
      directoryIssues: [],
      listing: { total: 1, limit: 200, truncated: false },
    })
  })

  it('separates producer-declared error rows from usable keepers once', () => {
    const data = Effect.runSync(decodeGateKeepers({
      count: 2,
      keepers: [keeperWire(), issueWire()],
      ...listingWire(2),
    }))

    expect(data.keepers.map(keeper => keeper.name)).toEqual(['planner'])
    expect(data.directoryIssues).toEqual([{
      keeperName: 'broken',
      message: 'invalid keeper config',
    }])
  })

  it('accepts a directory issue that retains persisted keeper metadata', () => {
    const row = issueWire('broken')
    const meta = keeperWire('broken').meta
    const data = Effect.runSync(decodeGateKeepers({
      count: 1,
      keepers: [{
        ...row,
        meta,
        created_at: meta.created_at,
        updated_at: meta.updated_at,
        autoboot_enabled: false,
        proactive_enabled: false,
      }],
      ...listingWire(1),
    }))

    expect(data).toEqual({
      keepers: [],
      directoryIssues: [{
        keeperName: 'broken',
        message: 'invalid keeper config',
      }],
      listing: { total: 1, limit: 200, truncated: false },
    })
  })

  it('accepts an explicit empty directory', () => {
    expect(Effect.runSync(decodeGateKeepers({
      count: 0,
      keepers: [],
      ...listingWire(0),
    }))).toEqual({
      keepers: [],
      directoryIssues: [],
      listing: { total: 0, limit: 200, truncated: false },
    })
  })

  it.each([
    ['missing outer fields', {}],
    ['non-object payload', null],
    ['malformed row', { count: 1, keepers: [{ name: 'orphan' }], ...listingWire(1) }],
    ['excess row property', {
      count: 1,
      keepers: [{ ...keeperWire(), unexpected: true }],
      ...listingWire(1),
    }],
    ['a response without the listing fields', {
      count: 1,
      keepers: [keeperWire()],
    }],
  ])('rejects %s instead of defaulting or dropping data', (_name, value) => {
    expectDrift(value)
  })

  it('rejects a count that disagrees with the returned rows', () => {
    const error = expectDrift({
      count: 2,
      keepers: [keeperWire()],
      ...listingWire(2),
    })
    expect(error.message).toContain('count')
    expect(error.message).toContain('keepers.length')
  })

  it('rejects identity disagreement inside a row', () => {
    const row = keeperWire()
    const error = expectDrift({
      count: 1,
      keepers: [{ ...row, meta: { ...row.meta, name: 'other' } }],
      ...listingWire(1),
    })
    expect(error.message).toContain('keepers.0.meta.name')
  })

  it('rejects an error envelope attributed to another keeper', () => {
    const row = issueWire()
    const error = expectDrift({
      count: 1,
      keepers: [{
        ...row,
        effective_meta_error: {
          ...row.effective_meta_error,
          keeper: 'other',
        },
      }],
      ...listingWire(1),
    })
    expect(error.message).toContain('effective_meta_error.keeper')
  })
})
