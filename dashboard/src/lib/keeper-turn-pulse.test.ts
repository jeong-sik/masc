import { describe, expect, it } from 'vitest'
import { TURN_SLOT_SECONDS, cadenceWindow, readKeeperTurnPulse, type KeeperTurnPulse } from './keeper-turn-pulse'

const slot = (starts_at: number, counts: Partial<Record<'ok' | 'rested' | 'failed' | 'scheduled' | 'reacted' | 'chat' | 'own' | 'unknown', number>>) => ({
  starts_at,
  ok: 0,
  rested: 0,
  failed: 0,
  scheduled: 0,
  reacted: 0,
  chat: 0,
  own: 0,
  unknown: 0,
  ...counts,
})

const now = 1_795_400_000
const current = Math.floor(now / TURN_SLOT_SECONDS) * TURN_SLOT_SECONDS

function reported(raw: unknown): KeeperTurnPulse {
  const reading = readKeeperTurnPulse(raw)
  if (reading.state !== 'reported') throw new Error(`expected a reported pulse, got ${reading.state}`)
  return reading.pulse
}

describe('readKeeperTurnPulse', () => {
  it('reads null and a missing field as a keeper with no pulse', () => {
    expect(readKeeperTurnPulse(null)).toEqual({ state: 'absent' })
    expect(readKeeperTurnPulse(undefined)).toEqual({ state: 'absent' })
  })

  it('rejects a slot off a half-hour boundary, causes that do not add up, and a repeated slot', () => {
    const base = { known_since: now - 90_000 }
    expect(readKeeperTurnPulse({ ...base, slots: [slot(current + 1, { ok: 1, own: 1 })] }).state).toBe('invalid')
    expect(readKeeperTurnPulse({ ...base, slots: [slot(current, { ok: 2, own: 1 })] }).state).toBe('invalid')
    expect(readKeeperTurnPulse({
      ...base,
      slots: [slot(current, { ok: 1, own: 1 }), slot(current, { ok: 1, chat: 1 })],
    }).state).toBe('invalid')
    expect(readKeeperTurnPulse({ ...base, slots: [], extra: 1 }).state).toBe('invalid')
  })
})

describe('cadenceWindow', () => {
  // The 6h window's oldest slot starts 11 slots back; 12 slots back is outside.
  const pulse = reported({
    known_since: now - 90_000,
    slots: [
      slot(current, { ok: 1, own: 1 }),
      slot(current - 11 * TURN_SLOT_SECONDS, { ok: 2, failed: 1, scheduled: 1, reacted: 1, chat: 1 }),
      slot(current - 12 * TURN_SLOT_SECONDS, { ok: 2, scheduled: 2 }),
    ],
  })

  it('counts the slots of the last hours, the current one included, by cause', () => {
    const six = cadenceWindow(pulse, now, 6)
    expect([six.turns, six.scheduled, six.reacted, six.chat, six.own, six.unknown]).toEqual([4, 1, 1, 1, 1, 0])
    expect(six.knownFrom).toBeNull()
    expect(cadenceWindow(pulse, now, 24).turns).toBe(6)
  })

  it('names where the server started knowing turns when that is inside the window', () => {
    const lateStart = reported({ known_since: now - 3_600, slots: [] })
    expect(cadenceWindow(lateStart, now, 6).knownFrom).toBe(now - 3_600)
  })
})
