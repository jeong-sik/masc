import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  GateKeepersSchemaDriftError,
  decodeGateKeepers,
} from './gate-keepers'

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
    agent_name: `keeper-${name}-agent`,
    status: 'running',
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
    agent_name: null,
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

describe('decodeGateKeepers', () => {
  it('decodes the current detailed wire shape into concrete product values', () => {
    const data = Effect.runSync(decodeGateKeepers({
      count: 1,
      keepers: [keeperWire()],
    }))

    expect(data).toEqual({
      keepers: [{
        name: 'planner',
        runtimeLabel: 'keeper-planner-agent',
        status: 'running',
      }],
      directoryIssues: [],
    })
  })

  it('separates producer-declared error rows from usable keepers once', () => {
    const data = Effect.runSync(decodeGateKeepers({
      count: 2,
      keepers: [keeperWire(), issueWire()],
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
        agent_name: 'keeper-broken-agent',
        created_at: meta.created_at,
        updated_at: meta.updated_at,
        autoboot_enabled: false,
        proactive_enabled: false,
      }],
    }))

    expect(data).toEqual({
      keepers: [],
      directoryIssues: [{
        keeperName: 'broken',
        message: 'invalid keeper config',
      }],
    })
  })

  it('resolves an identical runtime identity to an empty display label once', () => {
    const row = keeperWire('planner')
    const data = Effect.runSync(decodeGateKeepers({
      count: 1,
      keepers: [{ ...row, agent_name: row.name }],
    }))

    expect(data.keepers[0]?.runtimeLabel).toBe('')
  })

  it('accepts an explicit empty directory', () => {
    expect(Effect.runSync(decodeGateKeepers({ count: 0, keepers: [] })))
      .toEqual({ keepers: [], directoryIssues: [] })
  })

  it.each([
    ['missing outer fields', {}],
    ['non-object payload', null],
    ['malformed row', { count: 1, keepers: [{ name: 'orphan' }] }],
    ['excess row property', {
      count: 1,
      keepers: [{ ...keeperWire(), unexpected: true }],
    }],
  ])('rejects %s instead of defaulting or dropping data', (_name, value) => {
    expectDrift(value)
  })

  it('rejects a count that disagrees with the returned rows', () => {
    const error = expectDrift({ count: 2, keepers: [keeperWire()] })
    expect(error.message).toContain('count')
    expect(error.message).toContain('keepers.length')
  })

  it('rejects identity disagreement inside a row', () => {
    const row = keeperWire()
    const error = expectDrift({
      count: 1,
      keepers: [{ ...row, meta: { ...row.meta, name: 'other' } }],
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
    })
    expect(error.message).toContain('effective_meta_error.keeper')
  })
})
