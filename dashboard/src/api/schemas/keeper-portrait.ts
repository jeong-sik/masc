import { isRecord } from '../../lib/type-guards'

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

function isKeeperEquipment(value: unknown): value is KeeperEquipment {
  return isRecord(value) && Object.keys(value).length === Object.keys(EQUIPMENT_IDS).length
    && Object.keys(EQUIPMENT_IDS).every(slot => Object.hasOwn(value, slot))
    && EQUIPMENT_IDS.face.some(id => id === value.face)
    && EQUIPMENT_IDS.neck.some(id => id === value.neck)
    && EQUIPMENT_IDS.head.some(id => id === value.head)
    && EQUIPMENT_IDS.hand.some(id => id === value.hand)
    && EQUIPMENT_IDS.base.some(id => id === value.base)
}

/** Shared by execution observations and the lazy Gate wire decoder.
 * A malformed portrait is false; it is never a producer-declared unavailable row. */
export function isKeeperPortraitReading(value: unknown): value is KeeperPortraitReading {
  if (!isRecord(value) || !Object.hasOwn(value, 'state') || Object.keys(value).length !== 2) return false
  switch (value.state) {
    case 'ready': return Object.hasOwn(value, 'equipment') && isKeeperEquipment(value.equipment)
    case 'unavailable': return Object.hasOwn(value, 'reason')
      && typeof value.reason === 'string' && value.reason.trim().length > 0
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
