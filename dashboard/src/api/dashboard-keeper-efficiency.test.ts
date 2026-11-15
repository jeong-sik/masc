import { beforeEach, describe, expect, it, vi } from 'vitest'
import { get } from './core'
import {
  KEEPER_EFFICIENCY_GET_TIMEOUT_MS,
  KEEPER_EFFICIENCY_PATH,
  decodeKeeperEfficiencyMonth,
  fetchKeeperEfficiencyCurrentMonth,
  keeperEfficiencyRow,
  type KeeperEfficiencyDecodeError,
} from './dashboard-keeper-efficiency'

vi.mock('./core', () => ({ get: vi.fn() }))

// The shape Keeper_efficiency.month_view_to_json writes
// (lib/keeper_efficiency/keeper_efficiency.ml).
function wire(): Record<string, unknown> {
  return {
    schema: 'masc.keeper-efficiency/v1',
    month: '2026-11',
    generated_at: 1794787200.5,
    days_covered: 15,
    fleet: {
      turns_total: 40,
      calls_per_turn: 5.5,
      tool_s_per_turn: 12.25,
      output_tokens_per_turn: 800.0,
      input_tokens_per_turn: 90000.0,
      cost_usd_per_turn: 0.0,
    },
    keepers: [
      {
        keeper: 'alpha',
        turns: 30,
        input_tokens: 3000000,
        output_tokens: 24000,
        cost_usd: 0.0,
        calls: 180,
        failed: 6,
        deferred: 2,
        tool_ms: 420000.0,
      },
      {
        keeper: 'alpha-two',
        turns: 10,
        input_tokens: 600000,
        output_tokens: 8000,
        cost_usd: 1.5,
        calls: 40,
        failed: 0,
        deferred: 0,
        tool_ms: 70000.0,
      },
    ],
  }
}

function refusal(raw: unknown): KeeperEfficiencyDecodeError {
  const decoded = decodeKeeperEfficiencyMonth(raw)
  if (decoded.ok) throw new Error('the decoder read what it must refuse')
  return decoded.error
}

function withRow(change: Record<string, unknown>): Record<string, unknown> {
  const body = wire()
  const rows = body.keepers as Record<string, unknown>[]
  return { ...body, keepers: [rows[0], { ...rows[1], ...change }] }
}

function without(body: Record<string, unknown>, name: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(body).filter(([key]) => key !== name))
}

describe('decodeKeeperEfficiencyMonth', () => {
  it('reads the month view the server writes', () => {
    const decoded = decodeKeeperEfficiencyMonth(wire())
    expect(decoded).toEqual({
      ok: true,
      view: {
        month: '2026-11',
        generated_at: 1794787200.5,
        days_covered: 15,
        fleet: wire().fleet,
        keepers: wire().keepers,
      },
    })
  })

  it('reads a month that no Keeper worked in', () => {
    const decoded = decodeKeeperEfficiencyMonth({ ...wire(), days_covered: 0, keepers: [] })
    expect(decoded.ok && decoded.view.keepers).toEqual([])
  })

  it.each([
    ['null', null],
    ['a list', []],
    ['a string', 'masc.keeper-efficiency/v1'],
  ])('refuses a body that is %s', (_name, raw) => {
    expect(refusal(raw)).toEqual({ kind: 'not_an_object', at: 'body' })
  })

  it('refuses a schema it does not know and names it', () => {
    expect(refusal({ ...wire(), schema: 'masc.keeper-efficiency/v2' }))
      .toEqual({ kind: 'unexpected_schema', schema: 'masc.keeper-efficiency/v2' })
  })

  it.each(['schema', 'month', 'generated_at', 'days_covered', 'keepers', 'fleet'])(
    'refuses a body without %s',
    (name) => {
      expect(refusal(without(wire(), name))).toEqual({ kind: 'missing_field', field: name })
    },
  )

  it.each([
    ['2026-13'],
    ['2026-00'],
    ['2026-1'],
    ['26-11'],
    ['2026-11-15'],
  ])('refuses the month %s', (month) => {
    expect(refusal({ ...wire(), month })).toEqual({ kind: 'invalid_field', field: 'month', fault: 'not_a_month' })
  })

  // A count the server could not have written is refused where it stands: a
  // null or a string that became 0 would draw a Keeper that did nothing.
  it.each([
    ['null', null, 'not_a_number'],
    ['a string', '30', 'not_a_number'],
    ['a fraction', 30.5, 'not_an_integer'],
    ['below zero', -1, 'negative'],
  ] as const)('refuses a turn count that is %s', (_name, turns, fault) => {
    expect(refusal(withRow({ turns }))).toEqual({ kind: 'invalid_field', field: 'keepers[1].turns', fault })
  })

  it('refuses a row without one of its counts and says which row', () => {
    const body = wire()
    const rows = body.keepers as Record<string, unknown>[]
    const second = without(rows[1]!, 'failed')
    expect(refusal({ ...body, keepers: [rows[0], second] }))
      .toEqual({ kind: 'missing_field', field: 'keepers[1].failed' })
  })

  it('refuses a row that names no Keeper', () => {
    expect(refusal(withRow({ keeper: '' })))
      .toEqual({ kind: 'invalid_field', field: 'keepers[1].keeper', fault: 'empty' })
    expect(refusal(withRow({ keeper: 7 })))
      .toEqual({ kind: 'invalid_field', field: 'keepers[1].keeper', fault: 'not_a_string' })
  })

  it('refuses rows that are not a list, and a row that is not an object', () => {
    expect(refusal({ ...wire(), keepers: {} }))
      .toEqual({ kind: 'invalid_field', field: 'keepers', fault: 'not_a_list' })
    expect(refusal({ ...wire(), keepers: [(wire().keepers as unknown[])[0], 'alpha-two'] }))
      .toEqual({ kind: 'not_an_object', at: 'keepers[1]' })
  })

  it('refuses a fleet row that is not an object or lacks a measure', () => {
    expect(refusal({ ...wire(), fleet: [] })).toEqual({ kind: 'not_an_object', at: 'fleet' })
    const fleet = without(wire().fleet as Record<string, unknown>, 'tool_s_per_turn')
    expect(refusal({ ...wire(), fleet })).toEqual({ kind: 'missing_field', field: 'fleet.tool_s_per_turn' })
  })
})

describe('keeperEfficiencyRow', () => {
  it('picks the row of exactly that Keeper', () => {
    const decoded = decodeKeeperEfficiencyMonth(wire())
    if (!decoded.ok) throw new Error('the fixture did not decode')
    expect(keeperEfficiencyRow(decoded.view, 'alpha')?.turns).toBe(30)
    expect(keeperEfficiencyRow(decoded.view, 'alpha-two')?.turns).toBe(10)
    // A name that only begins like another is a different Keeper.
    expect(keeperEfficiencyRow(decoded.view, 'alph')).toBeNull()
    expect(keeperEfficiencyRow(decoded.view, 'beta')).toBeNull()
  })
})

describe('fetchKeeperEfficiencyCurrentMonth', () => {
  beforeEach(() => {
    vi.mocked(get).mockReset()
  })

  it('asks the route without a month, under the deadline of the first read of a month', async () => {
    vi.mocked(get).mockResolvedValue(wire())
    const controller = new AbortController()
    const view = await fetchKeeperEfficiencyCurrentMonth({ signal: controller.signal })
    expect(view.month).toBe('2026-11')
    expect(get).toHaveBeenCalledTimes(1)
    expect(get).toHaveBeenCalledWith(KEEPER_EFFICIENCY_PATH, {
      signal: controller.signal,
      timeoutMs: KEEPER_EFFICIENCY_GET_TIMEOUT_MS,
    })
    expect(KEEPER_EFFICIENCY_PATH).toBe('/api/v1/keeper-efficiency')
  })

  it('fails the read when the answer is not a month view', async () => {
    vi.mocked(get).mockResolvedValue({})
    await expect(fetchKeeperEfficiencyCurrentMonth()).rejects.toThrow()
    vi.mocked(get).mockResolvedValue({ ...wire(), schema: 'masc.keeper-efficiency/v2' })
    await expect(fetchKeeperEfficiencyCurrentMonth()).rejects.toThrow()
  })

  it('fails the read when the request fails', async () => {
    const failure = new Error('GET /api/v1/keeper-efficiency: 503')
    vi.mocked(get).mockRejectedValue(failure)
    await expect(fetchKeeperEfficiencyCurrentMonth()).rejects.toBe(failure)
  })
})
