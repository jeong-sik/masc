import { describe, expect, it } from 'vitest'
import { boardTargetReadings, readBoardAudience, readKeeperBoardAddress } from './board-address'
import { normalizeKeepers } from '../keeper-store-normalize'

const roster = (target_ids: string[]) => normalizeKeepers([
  { name: 'beta', status: 'offline', board_address: { state: 'ready', target_ids } },
])

describe('authoritative Board address projection', () => {
  it('matches a configured alias without inventing a display-name address', () => {
    const audience = readBoardAudience({ kind: 'targets', targets: ['Alpha', 'beta', 'keeper-beta'] })
    expect(boardTargetReadings(audience, roster(['alpha']))).toEqual([
      { target: 'Alpha', keepers: ['beta'], unresolved: false },
      { target: 'beta', keepers: [], unresolved: false },
      { target: 'keeper-beta', keepers: [], unresolved: false },
    ])
  })
  it('does not retain an alias index across successive effective configurations', () => {
    const audience = readBoardAudience({ kind: 'targets', targets: ['Alpha', 'Omega'] })
    expect(boardTargetReadings(audience, roster(['alpha'])).map(row => row.keepers)).toEqual([['beta'], []])
    expect(boardTargetReadings(audience, roster(['omega'])).map(row => row.keepers)).toEqual([[], ['beta']])
  })
  it('never treats missing or failed addresses as an empty known roster', () => {
    const audience = readBoardAudience({ kind: 'targets', targets: ['Alpha'] })
    expect(boardTargetReadings(audience, normalizeKeepers([{ name: 'beta', status: 'offline' }]))[0]).toEqual({
      target: 'Alpha', keepers: [], unresolved: true,
    })
    expect(boardTargetReadings(audience, [])[0]?.unresolved).toBe(true)
    expect(readKeeperBoardAddress({ state: 'unavailable', reason: 'effective_metadata_unread' })).toEqual({
      state: 'unavailable', reason: 'effective_metadata_unread',
    })
  })
  it.each([null, undefined])('retains unavailable for absent Board audience %s', raw => {
    expect(readBoardAudience(raw)).toEqual({ kind: 'unavailable', reason: 'not_recorded' })
  })
  it.each([
    { kind: 'targets', targets: [] }, { kind: 'targets', targets: ['Alpha', 'Alpha'] }, { kind: 'targets', targets: ['Alpha', 4] },
    { kind: 'targets', targets: [' Alpha'] }, { kind: 'broadcast', targets: ['Alpha'] },
    { kind: 'unknown' }, { kind: 'targets', targets: ['../alpha'] },
  ])('refuses malformed audience without parsing prose %#', raw => {
    expect(readBoardAudience(raw)).toEqual({ kind: 'unavailable', reason: 'invalid_payload' })
  })
  it.each(['broadcast', 'thread_participants', 'discoverable'])('retains closed %s audience', kind => {
    expect(readBoardAudience({ kind })).toEqual({ kind })
  })
  it.each([
    { state: 'ready', target_ids: ['Alpha'] }, { state: 'ready', target_ids: ['alpha', 'alpha'] },
    { state: 'ready', target_ids: ['alpha'], fallback: 'beta' },
    { state: 'unavailable', reason: 'guessed' },
  ])('refuses malformed address projection %#', raw => {
    expect(readKeeperBoardAddress(raw)).toEqual({ state: 'unavailable', reason: 'invalid_payload' })
  })
  it('uses the backend ASCII-only identity fold', () => {
    expect(readKeeperBoardAddress({ state: 'ready', target_ids: ['Älpha'] })).toEqual({ state: 'ready', target_ids: ['Älpha'] })
  })
})
