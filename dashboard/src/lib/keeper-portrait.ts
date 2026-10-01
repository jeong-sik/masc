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
export function readKeeperPortrait(value: unknown): KeeperPortraitReading {
  if (record(value)) {
    if (value.state === 'unavailable' && fields(value, ['state', 'reason'])
      && typeof value.reason === 'string' && value.reason.trim().length > 0) {
      return { state: 'unavailable', reason: value.reason }
    }
    const equipment = value.equipment
    if (value.state === 'ready' && fields(value, ['state', 'equipment'])
      && record(equipment) && fields(equipment, ['face', 'neck', 'head', 'hand', 'base'])
      && member(EQUIPMENT_IDS.face, equipment.face) && member(EQUIPMENT_IDS.neck, equipment.neck)
      && member(EQUIPMENT_IDS.head, equipment.head) && member(EQUIPMENT_IDS.hand, equipment.hand)
      && member(EQUIPMENT_IDS.base, equipment.base)) {
      return { state: 'ready', equipment: { face: equipment.face, neck: equipment.neck,
        head: equipment.head, hand: equipment.hand, base: equipment.base } }
    }
  }
  return { state: 'unavailable', reason: 'Portrait observation missing or malformed' }
}
export function keeperEquipmentKey(equipment: KeeperEquipment): string {
  return JSON.stringify([equipment.face, equipment.neck, equipment.head, equipment.hand, equipment.base])
}
