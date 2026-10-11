import { describe, expect, it, vi } from 'vitest'
vi.mock('./core', () => ({ fetchControlPlane: vi.fn(), apiRequestErrorFromResponse: vi.fn() }))
import { fetchControlPlane } from './core'
import { fetchKeeperCurrentTurn, fetchKeeperTurnEvents, parseKeeperTurnEventPage } from './keeper-turn-events'

const raw = { schema: 'masc.keeper_turn_events.v1', turn_ref: 'trace#9',
  ag_ui_events: [{ seq: 4, ts: 1, event: { type: 'TEXT_MESSAGE_CONTENT', threadId: 'keeper:k',
    runId: 'trace#9', messageId: 'trace#9:assistant', delta: 'answer', timestamp: 1 } }],
  has_more: false, next_since_seq: 4, next_since_offset: 123 }
const cursor = { sequence: 3, offset: 10 }
describe('autonomous turn journal boundary', () => {
  it('retains the exact turn cursor and projected content', () => {
    const page = parseKeeperTurnEventPage(raw, 'trace#9', cursor)
    expect(page.cursor).toEqual({ sequence: 4, offset: 123 })
    expect(page.events[0]?.event).toMatchObject({ delta: 'answer', runId: 'trace#9' })
    expect(Object.isFrozen(page.events)).toBe(true)
  })
  it.each([
    { turn_ref: 'other#9' },
    { ag_ui_events: [{ ...raw.ag_ui_events[0], event: { ...raw.ag_ui_events[0]!.event, runId: 'other#9' } }] }, { next_since_seq: 5 }, { next_since_offset: 10 },
    { ag_ui_events: [{ seq: 3, ts: 1, event: null }] },
    { ag_ui_events: [raw.ag_ui_events[0], raw.ag_ui_events[0]] },
    { ag_ui_events: [{ seq: 4, ts: 1, event: { type: 'unknown' } }] },
  ])('rejects foreign, repeated, and inconsistent pages %j', delta => {
    expect(() => parseKeeperTurnEventPage({ ...raw, ...delta }, 'trace#9', cursor)).toThrow()
  })
  it('accepts a scanned empty resume page without fabricating events or a newer sequence', () => {
    const page = parseKeeperTurnEventPage({ ...raw, ag_ui_events: [], has_more: false,
      next_since_seq: 3, next_since_offset: 123 }, 'trace#9', { sequence: 3, offset: 0 })
    expect(page.events).toEqual([])
    expect(page.cursor).toEqual({ sequence: 3, offset: 123 })
  })
  it.each([
    { has_more: true, next_since_seq: 3, next_since_offset: 123 },
    { has_more: false, next_since_seq: 4, next_since_offset: 123 },
    { has_more: false, next_since_seq: 3, next_since_offset: 9 },
  ])('rejects an empty page with false progress or backward bytes %j', delta => {
    expect(() => parseKeeperTurnEventPage({ ...raw, ag_ui_events: [], ...delta }, 'trace#9', cursor)).toThrow()
  })
  it('advances across connector-only rows without inventing UI content', () => {
    const page = parseKeeperTurnEventPage({ ...raw, ag_ui_events: [{ seq: 4, ts: 1, event: null }] }, 'trace#9', cursor)
    expect(page.events[0]?.event).toBeNull()
    expect(page.cursor.sequence).toBe(4)
  })
  it('feeds both cursor halves through the authenticated control-plane request', async () => {
    vi.mocked(fetchControlPlane).mockResolvedValueOnce(new Response(JSON.stringify(raw)))
    const controller = new AbortController()
    await fetchKeeperTurnEvents('k', 'trace#9', cursor, controller.signal)
    expect(fetchControlPlane).toHaveBeenCalledWith('/api/v1/keepers/k/turns/trace%239/events?since_seq=3&since_offset=10',
      { method: 'GET', signal: controller.signal })
  })
})


describe('current autonomous turn discovery', () => {
  it.each([
    [{ schema: 'masc.keeper_current_turn.v1', current: null }, { state: 'idle' }],
    [{ schema: 'masc.keeper_current_turn.v1', current: { turn_ref: 'trace#9', seq: 0 } }, { state: 'observed', turnRef: 'trace#9', sequence: 0 }],
  ])('reads explicit producer state', async (raw, expected) => {
    vi.mocked(fetchControlPlane).mockResolvedValueOnce(new Response(JSON.stringify(raw)))
    await expect(fetchKeeperCurrentTurn('k')).resolves.toEqual(expected)
  })
  it.each([{}, { current: {} }, { schema: 'masc.keeper_current_turn.v1' },
    { schema: 'masc.keeper_current_turn.v1', current: { turn_ref: 'trace#9', seq: -1 } }])('refuses incomplete discovery %j', async raw => {
    vi.mocked(fetchControlPlane).mockResolvedValueOnce(new Response(JSON.stringify(raw)))
    await expect(fetchKeeperCurrentTurn('k')).rejects.toThrow('Invalid current turn discovery')
  })
})
