import { describe, expect, it } from 'vitest'

import {
  isTerminalKeeperRunResult,
  keeperRunRefKey,
  keeperRunRefToWire,
  parseKeeperRunRef,
  parseKeeperRunResultContract,
  parseKeeperRunTerminal,
  parseKeeperRunTracking,
  sameKeeperRunRef,
} from './keeper-run-ref'

const RUN_REF_WIRE = {
  run_id: 'typed-run-1',
  target: { kind: 'keeper', name: 'luna' },
  capability: 'invoke_turn',
} as const

describe('Keeper run reference', () => {
  it('round-trips the exact immutable wire contract', () => {
    const reference = parseKeeperRunRef(RUN_REF_WIRE)

    expect(reference).toEqual({
      runId: 'typed-run-1',
      target: { kind: 'keeper', name: 'luna' },
      capability: 'invoke_turn',
    })
    expect(keeperRunRefToWire(reference)).toEqual(RUN_REF_WIRE)
    expect(Object.isFrozen(reference)).toBe(true)
    expect(Object.isFrozen(reference.target)).toBe(true)
  })

  it('rejects raw request ids and additional fields', () => {
    expect(() => parseKeeperRunRef({ request_id: 'typed-run-1' }))
      .toThrow('run_ref must contain exactly run_id, target, capability')
    expect(() => parseKeeperRunRef({ ...RUN_REF_WIRE, status: 'running' }))
      .toThrow('run_ref must contain exactly run_id, target, capability')
  })

  it('keys and compares the complete typed identity', () => {
    const luna = parseKeeperRunRef(RUN_REF_WIRE)
    const echo = parseKeeperRunRef({
      ...RUN_REF_WIRE,
      target: { kind: 'keeper', name: 'echo' },
    })

    expect(sameKeeperRunRef(luna, parseKeeperRunRef(RUN_REF_WIRE))).toBe(true)
    expect(sameKeeperRunRef(luna, echo)).toBe(false)
    expect(keeperRunRefKey(luna)).not.toBe(keeperRunRefKey(echo))
  })

  it('classifies only typed terminal result contracts', () => {
    expect(isTerminalKeeperRunResult(parseKeeperRunResultContract('running'))).toBe(false)
    expect(isTerminalKeeperRunResult(parseKeeperRunResultContract('yielded'))).toBe(true)
    expect(isTerminalKeeperRunResult(parseKeeperRunResultContract('failed'))).toBe(true)
    expect(() => parseKeeperRunResultContract('done')).toThrow(
      'unsupported Keeper run result contract',
    )
  })

  it('decodes typed Gate tracking and terminal envelopes', () => {
    const tracking = parseKeeperRunTracking({
      tracking: {
        kind: 'keeper_run',
        run_ref: RUN_REF_WIRE,
        result_contract: 'awaiting_execution',
      },
      destination_type: 'keeper',
      destination_id: 'luna',
    })
    expect(tracking.runRef).toEqual(parseKeeperRunRef(RUN_REF_WIRE))
    expect(tracking.resultContract).toBe('awaiting_execution')

    const terminal = parseKeeperRunTerminal({
      run_ref: RUN_REF_WIRE,
      result_contract: 'yielded',
      message: 'checkpoint',
    })
    expect(terminal.runRef).toEqual(tracking.runRef)
    expect(terminal.resultContract).toBe('yielded')
  })

  it('rejects retargeted and raw terminal SSE identities', () => {
    expect(() => parseKeeperRunTracking({
      tracking: {
        kind: 'keeper_run',
        run_ref: RUN_REF_WIRE,
        result_contract: 'running',
      },
      destination_type: 'keeper',
      destination_id: 'other',
    })).toThrow('destination must match run_ref.target')
    expect(() => parseKeeperRunTerminal({ request_id: 'typed-run-1', status: 'done' }))
      .toThrow('must contain run_ref, result_contract')
    expect(() => parseKeeperRunTerminal({ run_ref: RUN_REF_WIRE, result_contract: 'failed', message: 7 }))
      .toThrow('message must be a string')
  })
})
