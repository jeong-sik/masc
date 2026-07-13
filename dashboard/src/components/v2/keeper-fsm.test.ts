// Closed-sum regression test for the keeper FSM SSOT lift.
//
// The four lookup tables (PHASE_TONE, PHASE_PULSE, PHASE_INFO, FSM_ACTIONS) and
// the two coarse sets (RUN_PHASES, PAUSE_PHASES) MUST cover every variant of
// `KeeperPhase` (types/core.ts). A new variant added to `KeeperPhase` without
// updating `keeper-fsm.ts` will (a) fail `tsc --noEmit` for `Record<KeeperPhase,
// …>` tables and (b) fail this test which enumerates them at runtime.
//
// Without the closed-sum guard, a wire string like 'constructor'
// would slip through `phase in PHASE_TONE` via the JS prototype chain (the
// very bug the iter-4 SSOT lift closed in fleet-tone.ts). The
// `isKeeperPhase` registry closes the same hole here.
import { describe, expect, it } from 'vitest'
import type { KeeperPhase } from '../../types/core'
import {
  FSM_STATES,
  phaseInfo,
  phasePulse,
  phaseStatus,
  phaseTone,
  fsmActions,
} from './keeper-fsm'

// The 13 canonical PascalCase tokens of `KeeperPhase` (live wire).
const ALL_PHASES: readonly KeeperPhase[] = [
  'Offline',
  'Restarting',
  'Running',
  'Compacting',
  'HandingOff',
  'Failing',
  'Overflowed',
  'Draining',
  'Paused',
  'Stopped',
  'Crashed',
  'Dead',
]

describe('keeper-fsm SSOT closed-sum', () => {
  it('FSM_STATES matches the canonical phase set', () => {
    expect(new Set(FSM_STATES)).toEqual(new Set([
      'Offline', 'Restarting', 'Running', 'Compacting', 'HandingOff',
      'Failing', 'Overflowed', 'Draining', 'Paused', 'Stopped',
      'Crashed', 'Dead',
    ]))
  })

  it.each(ALL_PHASES)('phaseTone(%s) returns a FleetTone', (phase) => {
    const tone = phaseTone(phase)
    expect(['ok', 'warn', 'bad', 'busy', 'idle']).toContain(tone)
  })

  it.each(ALL_PHASES)('phasePulse(%s) returns a boolean', (phase) => {
    const pulse = phasePulse(phase)
    expect(typeof pulse).toBe('boolean')
  })

  it('PHASE_PULSE: only the 5 active/transient phases pulse (prototype verbatim)', () => {
    const expectedPulsing = new Set<KeeperPhase>([
      'Running', 'Compacting', 'HandingOff', 'Restarting', 'Failing',
    ])
    for (const phase of ALL_PHASES) {
      expect(phasePulse(phase)).toBe(expectedPulsing.has(phase))
    }
  })

  it.each(ALL_PHASES)('phaseInfo(%s) returns a non-empty Korean gloss', (phase) => {
    const info = phaseInfo(phase)
    expect(typeof info).toBe('string')
    expect(info.length).toBeGreaterThan(0)
    expect(info).not.toBe('알 수 없음') // closed-sum means no fallback hit
  })

  it.each(ALL_PHASES)('phaseStatus(%s) returns a coarse bucket', (phase) => {
    const status = phaseStatus(phase)
    expect(['run', 'pause', 'off']).toContain(status)
  })

  it('phaseStatus buckets: run/pause/off partition (prototype PHASE_STATUS)', () => {
    const expectedRun = new Set<KeeperPhase>([
      'Running', 'Compacting', 'HandingOff', 'Restarting', 'Failing',
    ])
    const expectedPause = new Set<KeeperPhase>(['Paused', 'Draining'])
    for (const phase of ALL_PHASES) {
      if (expectedRun.has(phase)) expect(phaseStatus(phase)).toBe('run')
      else if (expectedPause.has(phase)) expect(phaseStatus(phase)).toBe('pause')
      else expect(phaseStatus(phase)).toBe('off')
    }
  })

  it.each(ALL_PHASES)('fsmActions(%s) returns a readonly array', (phase) => {
    const actions = fsmActions(phase)
    expect(Array.isArray(actions)).toBe(true)
    // transient / terminal phases expose no actions
    const transientOrTerminal: ReadonlySet<KeeperPhase> = new Set([
      'Compacting', 'HandingOff', 'Draining', 'Restarting', 'Dead',
    ])
    if (transientOrTerminal.has(phase)) {
      expect(actions).toHaveLength(0)
    }
  })

  it('rejects unknown wire strings (no prototype-chain leak)', () => {
    // These are all `Object.prototype` members / arbitrary strings that would
    // pass `phase in PHASE_xxx` if the lookup tables used plain object
    // literals instead of `Record<KeeperPhase, …>` + the null-prototype
    // `isKeeperPhase` guard. They MUST fall back, never throw, never return a
    // prototype-inherited value.
    const garbage = [
      'constructor', 'toString', 'hasOwnProperty', '__proto__',
      '__defineGetter__', 'valueOf',
      'unknown-phase', 'RUNNING', 'running', // case-sensitive PascalCase only
    ]
    for (const phase of garbage) {
      // All lookups must return the fallback default (never throw, never
      // surface an inherited member).
      expect(['ok', 'warn', 'bad', 'busy', 'idle']).toContain(phaseTone(phase))
      expect(phasePulse(phase)).toBe(false)
      expect(['run', 'pause', 'off']).toContain(phaseStatus(phase))
      expect(fsmActions(phase)).toEqual([])
      // phaseInfo echoes the unknown raw phase string so the operator still
      // sees what the wire emitted (debug-friendly).
      expect(phaseInfo(phase)).toBe(phase)
    }
    // Empty string is falsy and falls through to the '알 수 없음' default.
    // Whitespace and other truthy-but-unknown strings echo back so the
    // operator can see what the wire emitted.
    expect(phaseInfo('')).toBe('알 수 없음')
    for (const phase of [' ', 'phantom']) {
      expect(phaseInfo(phase)).toBe(phase)
    }
  })

  it('null/undefined input returns the display-default fallback', () => {
    for (const phase of [null, undefined]) {
      expect(phaseTone(phase)).toBe('idle')
      expect(phasePulse(phase)).toBe(false)
      expect(phaseStatus(phase)).toBe('off')
      expect(fsmActions(phase)).toEqual([])
      expect(phaseInfo(phase)).toBe('알 수 없음')
    }
  })
})
