import { Either, Schema } from 'effect'

// Mirror of Keeper_turn_pulse.recent_turns_json (lib/keeper/keeper_turn_pulse.ml):
// half-hour slots, newest first, a slot with no turn left out. A slot counts
// its turns twice, by outcome (ok, rested, failed) and by what started them
// (scheduled, reacted, chat, own, unknown), so both sums are equal.
export const TURN_SLOT_SECONDS = 1800
const SECONDS_PER_HOUR = 3600
const SLOTS_PER_HOUR = SECONDS_PER_HOUR / TURN_SLOT_SECONDS

const KeeperTurnSlotSchema = Schema.Struct({
  starts_at: Schema.Int,
  ok: Schema.NonNegativeInt,
  rested: Schema.NonNegativeInt,
  failed: Schema.NonNegativeInt,
  scheduled: Schema.NonNegativeInt,
  reacted: Schema.NonNegativeInt,
  chat: Schema.NonNegativeInt,
  own: Schema.NonNegativeInt,
  unknown: Schema.NonNegativeInt,
}).pipe(Schema.filter(slot =>
  (slot.starts_at % TURN_SLOT_SECONDS === 0
    && slot.scheduled + slot.reacted + slot.chat + slot.own + slot.unknown
      === slot.ok + slot.rested + slot.failed)
  || 'turn slot is off a half-hour boundary or its causes do not add up to its outcomes',
))

export const KeeperTurnPulseSchema = Schema.Struct({
  known_since: Schema.Number,
  slots: Schema.Array(KeeperTurnSlotSchema),
}).pipe(Schema.filter(pulse =>
  new Set(pulse.slots.map(slot => slot.starts_at)).size === pulse.slots.length
  || 'turn pulse holds a slot twice',
))

export type KeeperTurnPulse = Schema.Schema.Type<typeof KeeperTurnPulseSchema>

export type KeeperTurnPulseReading =
  | { readonly state: 'reported'; readonly pulse: KeeperTurnPulse }
  | { readonly state: 'absent' }
  | { readonly state: 'invalid'; readonly reason: string }

/** [null] and a missing field are a keeper with no pulse yet; anything else
 *  that does not decode is reported as invalid, not as absent. */
export function readKeeperTurnPulse(raw: unknown): KeeperTurnPulseReading {
  if (raw === null || raw === undefined) return { state: 'absent' }
  const decoded = Schema.decodeUnknownEither(KeeperTurnPulseSchema, { onExcessProperty: 'error' })(raw)
  return Either.isRight(decoded)
    ? { state: 'reported', pulse: decoded.right }
    : { state: 'invalid', reason: 'turn pulse does not match the server shape' }
}

export const CADENCE_WINDOW_HOURS = [6, 24] as const

export interface CadenceWindow {
  readonly hours: number
  /** Every turn in the window's slots, of any outcome. */
  readonly turns: number
  readonly scheduled: number
  readonly reacted: number
  readonly chat: number
  readonly own: number
  readonly unknown: number
  /** Set when the server knows turns only from this Unix time, later than
   *  the window start, so the window is counted from here. */
  readonly knownFrom: number | null
}

/** The last [hours * 2] half-hour slots, the one holding [nowSeconds]
 *  included. */
export function cadenceWindow(pulse: KeeperTurnPulse, nowSeconds: number, hours: number): CadenceWindow {
  const currentSlot = Math.floor(nowSeconds / TURN_SLOT_SECONDS) * TURN_SLOT_SECONDS
  const windowStart = currentSlot - (hours * SLOTS_PER_HOUR - 1) * TURN_SLOT_SECONDS
  const inside = pulse.slots.filter(slot => slot.starts_at >= windowStart)
  const sum = (pick: (slot: KeeperTurnPulse['slots'][number]) => number) =>
    inside.reduce((total, slot) => total + pick(slot), 0)
  return {
    hours,
    turns: sum(slot => slot.ok + slot.rested + slot.failed),
    scheduled: sum(slot => slot.scheduled),
    reacted: sum(slot => slot.reacted),
    chat: sum(slot => slot.chat),
    own: sum(slot => slot.own),
    unknown: sum(slot => slot.unknown),
    knownFrom: pulse.known_since > windowStart ? pulse.known_since : null,
  }
}
