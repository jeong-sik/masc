// GET /api/v1/keeper-efficiency — one month of per-Keeper turn and tool totals
// with the run-weighted fleet row (lib/keeper_efficiency/keeper_efficiency.mli).
//
// One answer holds every Keeper of the month, so a reader of one Keeper picks
// that Keeper's row out of it (keeperEfficiencyRow). Asked without `month`,
// the server answers the current UTC month of its own clock; this module asks
// that way, so the month a page shows is the one the server counted, not one
// the browser's clock guessed.
//
// The decoder refuses what it cannot read. A schema it does not know, a
// missing field, a count that is negative or has a fraction, or a time no
// Date holds is an error that names the field; none of them becomes a zero.
//
// The TUI decoder (lib/tui_decode_keeper_efficiency.ml) reads the same answer
// of the server. The two differ on numbers the server does not write.
// JSON.parse hands over one number type, so `30.0` in a count position reads
// as the count 30 here and `0` in the position of a fraction reads as 0; the
// TUI refuses a float where it wants an int and an int where it wants a
// float. Only this decoder refuses a time past what a Date holds.

import { isRecord } from '../lib/type-guards'
import { get, type AbortableRequestOptions } from './core'

export const KEEPER_EFFICIENCY_PATH = '/api/v1/keeper-efficiency'
export const KEEPER_EFFICIENCY_SCHEMA = 'masc.keeper-efficiency/v1'

// The first read of a month folds every day file of that month; a later read
// takes only the bytes appended since (the boundary cache of the server). The
// first read of six days on a fleet of 33 Keepers took 41.7 s (#49066), past
// the default GET deadline of this dashboard. The TUI gives this read the
// same 120 s (bin/masc_tui_keeper_efficiency.ml).
export const KEEPER_EFFICIENCY_GET_TIMEOUT_MS = 120_000

/** Month totals of one Keeper. `cost_usd` is 0 for a lane that reports no
 *  money, so it cannot tell "nothing spent" from "not reported". */
export interface KeeperEfficiencyRow {
  readonly keeper: string
  readonly turns: number
  readonly input_tokens: number
  readonly output_tokens: number
  readonly cost_usd: number
  readonly calls: number
  readonly failed: number
  readonly deferred: number
  readonly tool_ms: number
}

/** The fleet row: totals of every Keeper divided by the fleet's turns. */
export interface KeeperEfficiencyFleet {
  readonly turns_total: number
  readonly calls_per_turn: number
  readonly tool_s_per_turn: number
  readonly output_tokens_per_turn: number
  readonly input_tokens_per_turn: number
  readonly cost_usd_per_turn: number
}

export interface KeeperEfficiencyMonth {
  /** "YYYY-MM", the month the server counted. */
  readonly month: string
  /** Unix seconds of the aggregation that answered, within what a Date holds. */
  readonly generated_at: number
  /** Days of the month with at least one ledger row. */
  readonly days_covered: number
  readonly keepers: readonly KeeperEfficiencyRow[]
  readonly fleet: KeeperEfficiencyFleet
}

/** Why a field was refused. */
export type KeeperEfficiencyFieldFault =
  | 'not_a_string'
  | 'empty'
  | 'not_a_number'
  | 'not_an_integer'
  | 'negative'
  | 'not_an_instant'
  | 'not_a_list'
  | 'not_a_month'

export type KeeperEfficiencyDecodeError =
  | { readonly kind: 'not_an_object'; readonly at: string }
  | { readonly kind: 'unexpected_schema'; readonly schema: string }
  | { readonly kind: 'missing_field'; readonly field: string }
  | { readonly kind: 'invalid_field'; readonly field: string; readonly fault: KeeperEfficiencyFieldFault }

interface Refused {
  readonly ok: false
  readonly error: KeeperEfficiencyDecodeError
}

export type KeeperEfficiencyDecoded =
  | { readonly ok: true; readonly view: KeeperEfficiencyMonth }
  | Refused

type Read<T> = { readonly ok: true; readonly value: T } | Refused

const read = <T>(value: T): Read<T> => ({ ok: true, value })
const refuse = (error: KeeperEfficiencyDecodeError): Refused => ({ ok: false, error })

type Fields = Record<string, unknown>

/** A member of `fields`, or the refusal of one that is not there. */
function member(fields: Fields, at: string, name: string): Read<unknown> {
  return Object.hasOwn(fields, name)
    ? read(fields[name])
    : refuse({ kind: 'missing_field', field: at + name })
}

function text(fields: Fields, at: string, name: string): Read<string> {
  const found = member(fields, at, name)
  if (!found.ok) return found
  const field = at + name
  if (typeof found.value !== 'string') return refuse({ kind: 'invalid_field', field, fault: 'not_a_string' })
  if (found.value === '') return refuse({ kind: 'invalid_field', field, fault: 'empty' })
  return read(found.value)
}

/** A finite number that is not below zero. */
function measure(fields: Fields, at: string, name: string): Read<number> {
  const found = member(fields, at, name)
  if (!found.ok) return found
  const field = at + name
  if (typeof found.value !== 'number' || !Number.isFinite(found.value)) {
    return refuse({ kind: 'invalid_field', field, fault: 'not_a_number' })
  }
  if (found.value < 0) return refuse({ kind: 'invalid_field', field, fault: 'negative' })
  return read(found.value)
}

/** A measure with no fraction. The producer's sums stop at the largest OCaml
 *  int, and JSON.parse rounds a count past 2^53 to the nearest number it
 *  holds; that is still a count, so it is read. */
function count(fields: Fields, at: string, name: string): Read<number> {
  const found = measure(fields, at, name)
  if (!found.ok) return found
  return Number.isInteger(found.value)
    ? found
    : refuse({ kind: 'invalid_field', field: at + name, fault: 'not_an_integer' })
}

// A Date holds up to 8.64e15 ms after the epoch.
const LAST_DATE_UNIX_SECONDS = 8.64e12

/** Unix seconds that a Date holds, so a page can draw the time. */
function instant(fields: Fields, at: string, name: string): Read<number> {
  const found = measure(fields, at, name)
  if (!found.ok) return found
  return found.value <= LAST_DATE_UNIX_SECONDS
    ? found
    : refuse({ kind: 'invalid_field', field: at + name, fault: 'not_an_instant' })
}

function row(raw: unknown, at: string): Read<KeeperEfficiencyRow> {
  if (!isRecord(raw)) return refuse({ kind: 'not_an_object', at })
  const inside = at + '.'
  const keeper = text(raw, inside, 'keeper')
  if (!keeper.ok) return keeper
  const turns = count(raw, inside, 'turns')
  if (!turns.ok) return turns
  const inputTokens = count(raw, inside, 'input_tokens')
  if (!inputTokens.ok) return inputTokens
  const outputTokens = count(raw, inside, 'output_tokens')
  if (!outputTokens.ok) return outputTokens
  const costUsd = measure(raw, inside, 'cost_usd')
  if (!costUsd.ok) return costUsd
  const calls = count(raw, inside, 'calls')
  if (!calls.ok) return calls
  const failed = count(raw, inside, 'failed')
  if (!failed.ok) return failed
  const deferred = count(raw, inside, 'deferred')
  if (!deferred.ok) return deferred
  const toolMs = measure(raw, inside, 'tool_ms')
  if (!toolMs.ok) return toolMs
  return read({
    keeper: keeper.value,
    turns: turns.value,
    input_tokens: inputTokens.value,
    output_tokens: outputTokens.value,
    cost_usd: costUsd.value,
    calls: calls.value,
    failed: failed.value,
    deferred: deferred.value,
    tool_ms: toolMs.value,
  })
}

function fleet(raw: unknown): Read<KeeperEfficiencyFleet> {
  if (!isRecord(raw)) return refuse({ kind: 'not_an_object', at: 'fleet' })
  const inside = 'fleet.'
  const turnsTotal = count(raw, inside, 'turns_total')
  if (!turnsTotal.ok) return turnsTotal
  const callsPerTurn = measure(raw, inside, 'calls_per_turn')
  if (!callsPerTurn.ok) return callsPerTurn
  const toolSPerTurn = measure(raw, inside, 'tool_s_per_turn')
  if (!toolSPerTurn.ok) return toolSPerTurn
  const outputTokensPerTurn = measure(raw, inside, 'output_tokens_per_turn')
  if (!outputTokensPerTurn.ok) return outputTokensPerTurn
  const inputTokensPerTurn = measure(raw, inside, 'input_tokens_per_turn')
  if (!inputTokensPerTurn.ok) return inputTokensPerTurn
  const costUsdPerTurn = measure(raw, inside, 'cost_usd_per_turn')
  if (!costUsdPerTurn.ok) return costUsdPerTurn
  return read({
    turns_total: turnsTotal.value,
    calls_per_turn: callsPerTurn.value,
    tool_s_per_turn: toolSPerTurn.value,
    output_tokens_per_turn: outputTokensPerTurn.value,
    input_tokens_per_turn: inputTokensPerTurn.value,
    cost_usd_per_turn: costUsdPerTurn.value,
  })
}

const MONTH_SHAPE = /^\d{4}-(?:0[1-9]|1[0-2])$/

function rows(raw: unknown): Read<readonly KeeperEfficiencyRow[]> {
  if (!Array.isArray(raw)) return refuse({ kind: 'invalid_field', field: 'keepers', fault: 'not_a_list' })
  const decoded: KeeperEfficiencyRow[] = []
  for (const [index, item] of raw.entries()) {
    const one = row(item, `keepers[${index}]`)
    if (!one.ok) return one
    decoded.push(one.value)
  }
  return read(decoded)
}

export function decodeKeeperEfficiencyMonth(raw: unknown): KeeperEfficiencyDecoded {
  if (!isRecord(raw)) return refuse({ kind: 'not_an_object', at: 'body' })
  const schema = text(raw, '', 'schema')
  if (!schema.ok) return schema
  if (schema.value !== KEEPER_EFFICIENCY_SCHEMA) {
    return refuse({ kind: 'unexpected_schema', schema: schema.value })
  }
  const month = text(raw, '', 'month')
  if (!month.ok) return month
  if (!MONTH_SHAPE.test(month.value)) {
    return refuse({ kind: 'invalid_field', field: 'month', fault: 'not_a_month' })
  }
  const generatedAt = instant(raw, '', 'generated_at')
  if (!generatedAt.ok) return generatedAt
  const daysCovered = count(raw, '', 'days_covered')
  if (!daysCovered.ok) return daysCovered
  const keepersRaw = member(raw, '', 'keepers')
  if (!keepersRaw.ok) return keepersRaw
  const keepers = rows(keepersRaw.value)
  if (!keepers.ok) return keepers
  const fleetRaw = member(raw, '', 'fleet')
  if (!fleetRaw.ok) return fleetRaw
  const fleetRow = fleet(fleetRaw.value)
  if (!fleetRow.ok) return fleetRow
  return {
    ok: true,
    view: {
      month: month.value,
      generated_at: generatedAt.value,
      days_covered: daysCovered.value,
      keepers: keepers.value,
      fleet: fleetRow.value,
    },
  }
}

export function keeperEfficiencyDecodeErrorText(error: KeeperEfficiencyDecodeError): string {
  switch (error.kind) {
    case 'not_an_object':
      return `keeper efficiency: ${error.at} is not an object`
    case 'unexpected_schema':
      return `keeper efficiency: schema ${JSON.stringify(error.schema)} is not ${JSON.stringify(KEEPER_EFFICIENCY_SCHEMA)}`
    case 'missing_field':
      return `keeper efficiency: missing ${error.field}`
    case 'invalid_field':
      return `keeper efficiency: invalid ${error.field}: ${error.fault}`
  }
}

/** The row of one Keeper, or null when the month holds no row of that name. */
export function keeperEfficiencyRow(view: KeeperEfficiencyMonth, keeper: string): KeeperEfficiencyRow | null {
  return view.keepers.find(candidate => candidate.keeper === keeper) ?? null
}

/** Reads the current month of the server. An answer the decoder refuses is a
 *  failed read, as a refused request is. */
export async function fetchKeeperEfficiencyCurrentMonth(
  opts?: AbortableRequestOptions,
): Promise<KeeperEfficiencyMonth> {
  const raw = await get<unknown>(KEEPER_EFFICIENCY_PATH, {
    signal: opts?.signal,
    timeoutMs: KEEPER_EFFICIENCY_GET_TIMEOUT_MS,
  })
  const decoded = decodeKeeperEfficiencyMonth(raw)
  if (!decoded.ok) throw new Error(keeperEfficiencyDecodeErrorText(decoded.error))
  return decoded.view
}
