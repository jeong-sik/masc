import { describe, expect, it } from 'vitest'
import { normalizeKeeperTurnsResponse } from './dashboard-keeper-turns'
import { FINISH_GLOW_TTL_MS, advanceFinishes, finishGlowFor, runningTurnFor } from '../components/keeper-turns-state'

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

// Mirrors the TUI's advance_finishes contract (#31208): running→idle is a
// finish; unavailable→idle and disappearing are not; restarting drops the
// glow; the TTL expires by the reader's clock.
describe('advanceFinishes', () => {
  const running = (name: string) => ({
    keeper_name: name,
    status: 'ok' as const,
    turn: { lane: 'autonomous', started_at_unix: 1 },
  })
  const idle = (name: string) => ({ keeper_name: name, status: 'ok' as const, turn: null })
  const unavailable = (name: string) => ({
    keeper_name: name,
    status: 'unavailable' as const,
    turn: null,
    detail: 'owner_not_found',
  })

  it('running→idle is a finish; unavailable→idle and vanishing are not', () => {
    const previous = [running('kidsnote'), unavailable('rondo'), running('gone')]
    const current = [idle('kidsnote'), idle('rondo')]
    expect(advanceFinishes(1000, previous, current, [])).toEqual([
      { keeper_name: 'kidsnote', finished_at_ms: 1000 },
    ])
  })

  it('a keeper that starts running again drops its glow', () => {
    const finishes = [{ keeper_name: 'kidsnote', finished_at_ms: 1000 }]
    const next = advanceFinishes(2000, [idle('kidsnote')], [running('kidsnote')], finishes)
    expect(next).toEqual([])
  })

  it('the glow expires by the reader clock, not the poll', () => {
    const finishes = [{ keeper_name: 'kidsnote', finished_at_ms: 1000 }]
    expect(finishGlowFor(finishes, 'kidsnote', 1000 + FINISH_GLOW_TTL_MS)).not.toBeNull()
    expect(finishGlowFor(finishes, 'kidsnote', 1001 + FINISH_GLOW_TTL_MS)).toBeNull()
    expect(
      advanceFinishes(1001 + FINISH_GLOW_TTL_MS, [idle('kidsnote')], [idle('kidsnote')], finishes),
    ).toEqual([])
  })
})
