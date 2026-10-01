import { Either, Schema } from 'effect'

// Wire vocabulary mirrors Keeper_portrait_item; the parity test reads its
// actual constructor-to-id mappings so adding equipment cannot silently drift.
export const EQUIPMENT_IDS = {
  face: ['bare_face', 'glasses', 'shades', 'eye_patch', 'plaster', 'freckles', 'beard'],
  neck: ['bare_neck', 'scarf', 'bow_tie', 'medal'],
  head: ['bare_head', 'bow', 'crown', 'beanie'],
  hand: ['empty_hand', 'book', 'mug', 'quill'],
  base: ['no_dish', 'dish_gilt', 'dish_silver', 'dish_oak'],
} as const

export const KeeperEquipmentSchema = Schema.Struct({
  face: Schema.Literal(...EQUIPMENT_IDS.face),
  neck: Schema.Literal(...EQUIPMENT_IDS.neck),
  head: Schema.Literal(...EQUIPMENT_IDS.head),
  hand: Schema.Literal(...EQUIPMENT_IDS.hand),
  base: Schema.Literal(...EQUIPMENT_IDS.base),
})
export const KeeperPortraitSchema = Schema.Union(
  Schema.Struct({ state: Schema.Literal('ready'), equipment: KeeperEquipmentSchema }),
  Schema.Struct({ state: Schema.Literal('unavailable'), reason: Schema.String.pipe(Schema.filter(value => value.trim().length > 0)) }),
)
export type KeeperEquipment = Schema.Schema.Type<typeof KeeperEquipmentSchema>
export type KeeperPortraitReading = Schema.Schema.Type<typeof KeeperPortraitSchema>

export function readKeeperPortrait(value: unknown): KeeperPortraitReading {
  const parsed = Schema.decodeUnknownEither(KeeperPortraitSchema, { onExcessProperty: 'error' })(value)
  return Either.isRight(parsed)
    ? parsed.right
    : { state: 'unavailable', reason: 'Portrait observation missing or malformed' }
}

export function keeperEquipmentKey(equipment: KeeperEquipment): string {
  return JSON.stringify([equipment.face, equipment.neck, equipment.head, equipment.hand, equipment.base])
}
