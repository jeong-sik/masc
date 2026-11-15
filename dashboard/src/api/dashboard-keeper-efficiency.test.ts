import { beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'
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
// (lib/keeper_efficiency/keeper_efficiency.ml). Every float of it carries a
// fraction here, so a float read as a count is refused by the first test.
function wire(): Record<string, unknown> {
  return {
    schema: 'masc.keeper-efficiency/v1',
    month: '2026-11',
    generated_at: 1794787200.5,
    days_covered: 15,
    fleet: {
      turns_total: 40,
      calls_per_turn: 5.5,
      tool_s_per_turn: 12.25001875,
      output_tokens_per_turn: 800.25,
      input_tokens_per_turn: 90000.25,
      cost_usd_per_turn: 0.0375,
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
        tool_ms: 420000.25,
      },
      {
        keeper: 'alpha-two',
        turns: 10,
        input_tokens: 600010,
        output_tokens: 8010,
        cost_usd: 1.5,
        calls: 40,
        failed: 0,
        deferred: 0,
        tool_ms: 70000.5,
      },
    ],
  }
}

const COUNT_FIELDS = [
  'days_covered',
  'fleet.turns_total',
  'keepers[1].turns',
  'keepers[1].input_tokens',
  'keepers[1].output_tokens',
  'keepers[1].calls',
  'keepers[1].failed',
  'keepers[1].deferred',
] as const

const FLOAT_FIELDS = [
  'generated_at',
  'fleet.calls_per_turn',
  'fleet.tool_s_per_turn',
  'fleet.output_tokens_per_turn',
  'fleet.input_tokens_per_turn',
  'fleet.cost_usd_per_turn',
  'keepers[1].cost_usd',
  'keepers[1].tool_ms',
] as const

const NUMBER_FIELDS = [...COUNT_FIELDS, ...FLOAT_FIELDS] as const

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

const FLEET = 'fleet.'
const SECOND_ROW = 'keepers[1].'

/** The wire body with one number field, named by the path the decoder
 *  reports, changed by `change`. */
function changed(
  field: (typeof NUMBER_FIELDS)[number],
  change: (fields: Record<string, unknown>, name: string) => Record<string, unknown>,
): Record<string, unknown> {
  const body = wire()
  if (field.startsWith(FLEET)) {
    return { ...body, fleet: change(body.fleet as Record<string, unknown>, field.slice(FLEET.length)) }
  }
  if (field.startsWith(SECOND_ROW)) {
    const rows = body.keepers as Record<string, unknown>[]
    return { ...body, keepers: [rows[0], change(rows[1]!, field.slice(SECOND_ROW.length))] }
  }
  return change(body, field)
}

function withNumber(field: (typeof NUMBER_FIELDS)[number], value: unknown): Record<string, unknown> {
  return changed(field, (fields, name) => ({ ...fields, [name]: value }))
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

  // A number the server could not have written is refused where it stands: a
  // null or a string that became 0 would draw a Keeper that did nothing.
  describe.each(NUMBER_FIELDS)('the number %s', (field) => {
    it.each([
      ['null', null, 'not_a_number'],
      ['a string', '30', 'not_a_number'],
      // What JSON.parse makes of 1e999.
      ['not finite', Number.POSITIVE_INFINITY, 'not_a_number'],
      ['below zero', -1, 'negative'],
    ] as const)('is refused when it is %s', (_name, value, fault) => {
      expect(refusal(withNumber(field, value))).toEqual({ kind: 'invalid_field', field, fault })
    })

    it('is refused when it is missing', () => {
      expect(refusal(changed(field, without))).toEqual({ kind: 'missing_field', field })
    })
  })

  it.each(COUNT_FIELDS)('refuses a fraction in the count %s', (field) => {
    expect(refusal(withNumber(field, 30.5))).toEqual({ kind: 'invalid_field', field, fault: 'not_an_integer' })
  })

  // The producer's sums stop at the largest OCaml int. JSON.parse rounds
  // that to 2^62; refusing it would fail the month of every Keeper.
  it.each(COUNT_FIELDS)('reads the count %s where the producer saturates', (field) => {
    const saturated: unknown = JSON.parse('4611686018427387903')
    expect(saturated).toBe(2 ** 62)
    expect(decodeKeeperEfficiencyMonth(withNumber(field, saturated)).ok).toBe(true)
  })

  // The page draws this time through a Date.
  it('reads the last time a Date holds and refuses a later one', () => {
    const lastDateSeconds = 8.64e12
    expect(Number.isNaN(new Date(lastDateSeconds * 1000).getTime())).toBe(false)
    const read = decodeKeeperEfficiencyMonth({ ...wire(), generated_at: lastDateSeconds })
    expect(read.ok && read.view.generated_at).toBe(lastDateSeconds)
    expect(Number.isNaN(new Date((lastDateSeconds + 1) * 1000).getTime())).toBe(true)
    expect(refusal({ ...wire(), generated_at: lastDateSeconds + 1 }))
      .toEqual({ kind: 'invalid_field', field: 'generated_at', fault: 'not_an_instant' })
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

  it('refuses a fleet row that is not an object', () => {
    expect(refusal({ ...wire(), fleet: [] })).toEqual({ kind: 'not_an_object', at: 'fleet' })
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

  // The first read of a month outlasts the default GET deadline; a read
  // under that default would fail before the server answered.
  it('asks the route without a month, under a deadline longer than the default one', async () => {
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
    expect(KEEPER_EFFICIENCY_GET_TIMEOUT_MS).toBeGreaterThan(DEFAULT_GET_TIMEOUT_MS)
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
