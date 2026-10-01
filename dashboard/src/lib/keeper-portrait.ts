// Wire vocabulary mirrors Keeper_portrait_item; the parity test reads its
// actual constructor-to-id mappings so adding equipment cannot silently drift.
export const EQUIPMENT_IDS = {
  face: ['bare_face', 'glasses', 'shades', 'eye_patch', 'plaster', 'freckles', 'beard'],
  neck: ['bare_neck', 'scarf', 'bow_tie', 'medal'],
  head: ['bare_head', 'bow', 'crown', 'beanie'],
  hand: ['empty_hand', 'book', 'mug', 'quill'],
  base: ['no_dish', 'dish_gilt', 'dish_silver', 'dish_oak'],
} as const

export type KeeperEquipment = {
  readonly [Slot in keyof typeof EQUIPMENT_IDS]: typeof EQUIPMENT_IDS[Slot][number]
}
export type KeeperPortraitReading =
  | { readonly state: 'ready'; readonly equipment: KeeperEquipment }
  | { readonly state: 'unavailable'; readonly reason: string }

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
function fields(value: Record<string, unknown>, names: readonly string[]): boolean {
  return Object.keys(value).length === names.length && names.every(name => Object.hasOwn(value, name))
}
function member<Id extends string>(ids: readonly Id[], value: unknown): value is Id {
  return typeof value === 'string' && ids.some(id => id === value)
}
export function isKeeperEquipment(value: unknown): value is KeeperEquipment {
  return record(value) && fields(value, ['face', 'neck', 'head', 'hand', 'base'])
    && member(EQUIPMENT_IDS.face, value.face) && member(EQUIPMENT_IDS.neck, value.neck)
    && member(EQUIPMENT_IDS.head, value.head) && member(EQUIPMENT_IDS.hand, value.hand)
    && member(EQUIPMENT_IDS.base, value.base)
}

/** A malformed portrait is not a producer-declared unavailable row. */
export function isKeeperPortraitReading(value: unknown): value is KeeperPortraitReading {
  if (!record(value) || !Object.hasOwn(value, 'state')) return false
  switch (value.state) {
    case 'unavailable': return fields(value, ['state', 'reason'])
      && typeof value.reason === 'string' && value.reason.trim().length > 0
    case 'ready': return fields(value, ['state', 'equipment']) && isKeeperEquipment(value.equipment)
    default: return false
  }
}

export function readKeeperPortrait(value: unknown): KeeperPortraitReading {
  if (!isKeeperPortraitReading(value)) {
    return Object.freeze({ state: 'unavailable', reason: 'Portrait observation missing or malformed' })
  }
  return value.state === 'ready'
    ? Object.freeze({ state: 'ready', equipment: Object.freeze({ ...value.equipment }) })
    : Object.freeze({ state: 'unavailable', reason: value.reason })
}
export function keeperEquipmentKey(equipment: KeeperEquipment): string {
  return JSON.stringify([equipment.face, equipment.neck, equipment.head, equipment.hand, equipment.base])
}
