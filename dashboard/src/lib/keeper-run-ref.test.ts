import { describe, expect, it } from 'vitest'

import {
  isTerminalKeeperRunResult,
  keeperRunRefKey,
  keeperRunRefToWire,
  parseKeeperRunRef,
  parseKeeperRunResultContract,
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
})
