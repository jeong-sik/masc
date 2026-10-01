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
    candle_balance_milli: null,
    candle_account_revision: null,
    portrait: { state: 'ready', equipment: { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } },
    name,
    meta: {
      name,
      sandbox_profile: 'docker',
      trace_id: `trace-${name}`,
      created_at: '2026-08-12T00:00:00Z',
      updated_at: '2026-08-12T00:01:00Z',
    },
    status: 'running',
    phase: 'active',
    health: 'healthy',
    paused: false,
    next_action: null,
    runtime_blocker_summary: null,
    keepalive_running: true,
    activation_mode: 'on_demand',
    runtime_id: `runtime-${name}`,
    created_at: '2026-08-12T00:00:00Z',
    updated_at: '2026-08-12T00:01:00Z',
  }
}

function issueWire(name = 'broken') {
  return {
    status: 'error',
    runtime_class: 'keeper',
    candle_balance_milli: null,
    candle_account_revision: null,
    portrait: { state: 'ready', equipment: { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } },
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
      candle: { status: 'off' },
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

  it('accepts nullable canonical account revisions across all row variants', () => {
    const healthy = keeperWire()
    const issue = issueWire()
    const retained = { ...issue, meta: healthy.meta, name: healthy.name,
      effective_meta_error: { ...issue.effective_meta_error, keeper: healthy.name },
      created_at: healthy.created_at, updated_at: healthy.updated_at, activation_mode: 'manual' }
    for (const row of [healthy, issue, retained]) {
      for (const revision of [null, 'a'.repeat(64)]) {
        expect(() => Effect.runSync(decodeGateKeepers({
          candle: { status: 'off' }, count: 1, ...listingWire(1),
          keepers: [{ ...row, candle_account_revision: revision }],
        }))).not.toThrow()
      }
      for (const revision of [undefined, '', 'A'.repeat(64), 'a'.repeat(63), 12]) {
        expectDrift({ candle: { status: 'off' }, count: 1, ...listingWire(1),
          keepers: [{ ...row, candle_account_revision: revision }] })
      }
    }
  })

  it('accepts the roster current failure without changing the compact product values', () => {
    const data = Effect.runSync(decodeGateKeepers({
      candle: { status: 'off' },
      count: 1,
      keepers: [{ ...keeperWire(), runtime_blocker_summary: 'current failure' }],
      ...listingWire(1),
    }))
    expect(data.keepers).toEqual([{ name: 'planner', status: 'running' }])
  })

  it('keeps lifecycle controls readable when only the Candle observation is malformed', () => {
    for (const [candle, balance] of [[undefined, undefined], [null, 123], [{ status: 'off' }, '1']]) {
      const data = Effect.runSync(decodeGateKeepers({
        candle, count: 1,
        keepers: [{ ...keeperWire(), candle_balance_milli: balance }],
        ...listingWire(1),
      }))
      expect(data.keepers).toEqual([{ name: 'planner', status: 'running' }])
      expect(data.directoryIssues).toEqual([])
    }
  })

  it('keeps lifecycle discovery independent of omitted or malformed account revisions', () => {
    const revision = 'a'.repeat(64)
    const issue = issueWire()
    const persisted = { ...issueWire('persisted'), meta: keeperWire('persisted').meta,
      created_at: '2026-08-12T00:00:00Z', updated_at: '2026-08-12T00:01:00Z', activation_mode: 'on_demand' }
    const data = Effect.runSync(decodeGateKeepers({
      candle: { status: 'ready', issued_milli: '0', burned_milli: '0', circulating_milli: '0' }, count: 3,
      keepers: [keeperWire(), issue, persisted].map(row => ({ ...row, candle_balance_milli: '0', candle_account_revision: revision })),
      ...listingWire(3),
    }))
    expect(data.keepers).toEqual([{ name: 'planner', status: 'running' }])
    expect(data.directoryIssues.map(issue => issue.keeperName)).toEqual(['broken', 'persisted'])
    for (const value of [undefined, '', 'A'.repeat(64), revision + '\n', 1]) {
      const decoded = Effect.runSync(decodeGateKeepers({ count: 1,
        keepers: [{ ...keeperWire(), candle_account_revision: value }], ...listingWire(1) }))
      expect(decoded.keepers).toEqual([{ name: 'planner', status: 'running' }])
    }
  })

  it('accepts a nonempty sandbox name this consumer does not interpret', () => {
    const wire = keeperWire()
    wire.meta.sandbox_profile = 'uninterpreted-sandbox'
    const data = Effect.runSync(decodeGateKeepers({
      candle: { status: 'off' },
      count: 1, keepers: [wire], ...listingWire(1),
    }))
    expect(data.keepers).toEqual([{ name: 'planner', status: 'running' }])
  })

  it.each(['missing', 'empty'] as const)('rejects a %s sandbox name', kind => {
    const wire = keeperWire()
    const meta: Record<string, unknown> = { ...wire.meta }
    if (kind === 'missing') delete meta.sandbox_profile
    else meta.sandbox_profile = ''
    const error = expectDrift({
      candle: { status: 'off' },
      count: 1, keepers: [{ ...wire, meta }], ...listingWire(1),
    })
    expect(error.issues.some(issue => issue.path.join('.') === 'keepers.0.meta.sandbox_profile')).toBe(true)
  })

  it('rejects an omitted current failure field', () => {
    const wire: Record<string, unknown> = keeperWire()
    delete wire.runtime_blocker_summary
    expectDrift({ candle: { status: 'off' }, count: 1, keepers: [wire], ...listingWire(1) })
  })

  it('separates producer-declared error rows from usable keepers once', () => {
    const data = Effect.runSync(decodeGateKeepers({
      candle: { status: 'off' },
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
      candle: { status: 'off' },
      count: 1,
      keepers: [{
        ...row,
        meta,
        created_at: meta.created_at,
        updated_at: meta.updated_at,
        activation_mode: 'manual',
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
      candle: { status: 'off' },
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
    ['malformed row', { candle: { status: 'off' }, count: 1, keepers: [{ name: 'orphan' }], ...listingWire(1) }],
    ['excess row property', {
      candle: { status: 'off' },
      count: 1,
      keepers: [{ ...keeperWire(), unexpected: true }],
      ...listingWire(1),
    }],
    ['a response without the listing fields', {
      candle: { status: 'off' },
      count: 1,
      keepers: [keeperWire()],
    }],
  ])('rejects %s instead of defaulting or dropping data', (_name, value) => {
    expectDrift(value)
  })

  it('rejects a count that disagrees with the returned rows', () => {
    const error = expectDrift({
      candle: { status: 'off' },
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
      candle: { status: 'off' },
      count: 1,
      keepers: [{ ...row, meta: { ...row.meta, name: 'other' } }],
      ...listingWire(1),
    })
    expect(error.message).toContain('keepers.0.meta.name')
  })

  it('rejects an error envelope attributed to another keeper', () => {
    const row = issueWire()
    const error = expectDrift({
      candle: { status: 'off' },
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

  it('retains producer-declared Portrait unavailability in a readable Gate roster', () => {
    const data = Effect.runSync(decodeGateKeepers({
      candle: { status: 'off' }, count: 1,
      keepers: [{ ...keeperWire(), portrait: { state: 'unavailable', reason: 'ledger unreadable' } }],
      ...listingWire(1),
    }))
    expect(data.keepers).toEqual([{ name: 'planner', status: 'running' }])
    expect(data.directoryIssues).toEqual([])
  })

  it('reports malformed Portrait data as typed Gate drift instead of readable unavailability', () => {
    const equipment = keeperWire().portrait.equipment
    for (const portrait of [undefined, null, { state: 'ready' },
      { state: 'ready', equipment: { ...equipment, head: 'medal' } },
      { state: 'ready', equipment: { ...equipment, extra: 'crown' } },
      { state: 'ready', equipment, extra: true }, { state: 'unavailable', reason: ' ' },
      { state: 'unavailable', reason: 'ledger unreadable', extra: true }]) {
      const error = expectDrift({ candle: { status: 'off' }, count: 1,
        keepers: [{ ...keeperWire(), portrait }], ...listingWire(1) })
      expect(error.issues.some(issue => issue.path.join('.') === 'keepers.0.portrait')).toBe(true)
    }
  })

})
