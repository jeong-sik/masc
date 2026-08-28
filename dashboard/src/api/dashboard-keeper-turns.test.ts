import { describe, expect, it } from 'vitest'
import { normalizeKeeperTurnsResponse } from './dashboard-keeper-turns'
import { runningTurnFor } from '../components/keeper-turns-state'

// The badge must never guess: an unknown schema or a mistyped row is an
// error, and idle/unavailable/absent all read as "no badge", never as a turn.

describe('normalizeKeeperTurnsResponse', () => {
  const wire = {
    schema: 'masc.keeper_turns.v1',
    keepers: [
      {
        keeper_name: 'kidsnote',
        status: 'ok',
        turn: { lane: 'autonomous', started_at_unix: 1787828193.5 },
      },
      { keeper_name: 'analyst', status: 'ok', turn: null },
      { keeper_name: 'rondo', status: 'unavailable', detail: 'owner_not_found', turn: null },
    ],
  }

  it('reads running, idle, and unavailable rows', () => {
    const parsed = normalizeKeeperTurnsResponse(wire)
    expect(parsed.keepers).toHaveLength(3)
    expect(parsed.keepers[0]!.turn).toEqual({ lane: 'autonomous', started_at_unix: 1787828193.5 })
    expect(parsed.keepers[1]!.turn).toBeNull()
    expect(parsed.keepers[2]!.status).toBe('unavailable')
    expect(parsed.keepers[2]!.detail).toBe('owner_not_found')
  })

  it('rejects an unknown schema instead of defaulting', () => {
    expect(() => normalizeKeeperTurnsResponse({ schema: 'masc.keeper_turns.v2', keepers: [] }))
      .toThrow(/unknown schema/)
  })

  it('rejects a mistyped turn instead of dropping it', () => {
    expect(() =>
      normalizeKeeperTurnsResponse({
        schema: 'masc.keeper_turns.v1',
        keepers: [{ keeper_name: 'x', status: 'ok', turn: { lane: 7 } }],
      }),
    ).toThrow(/neither null nor/)
  })

  it('runningTurnFor answers only a definite ok row with a turn', () => {
    const rows = normalizeKeeperTurnsResponse(wire).keepers
    expect(runningTurnFor(rows, 'kidsnote')?.lane).toBe('autonomous')
    expect(runningTurnFor(rows, 'analyst')).toBeNull()
    expect(runningTurnFor(rows, 'rondo')).toBeNull()
    expect(runningTurnFor(rows, 'nobody')).toBeNull()
  })
})
