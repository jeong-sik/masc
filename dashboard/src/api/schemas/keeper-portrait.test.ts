import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { EQUIPMENT_IDS, keeperEquipmentKey, readKeeperPortrait } from './keeper-portrait'

const equipment = { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } as const

describe('server portrait snapshots', () => {
  it('requires complete equipment and never repairs unknown or cross-slot items', () => {
    const ready = readKeeperPortrait({ state: 'ready', equipment })
    expect(ready).toEqual({ state: 'ready', equipment })
    for (const raw of [undefined, null, { state: 'ready' }, { state: 'ready', equipment: { head: 'crown' } },
      { state: 'ready', equipment: { ...equipment, head: 'medal' } },
      { state: 'ready', equipment: { ...equipment, extra: 'crown' } },
      { state: 'unavailable', reason: ' ' }]) {
      expect(readKeeperPortrait(raw).state).toBe('unavailable')
    }
    const worn = { ...equipment, head: 'crown' } as const
    expect(keeperEquipmentKey(equipment)).not.toBe(keeperEquipmentKey(worn))
  })

  it('matches every slot and item id in the canonical OCaml catalog', () => {
    const source = readFileSync(resolve(__dirname, '../../../../lib/keeper_portrait/keeper_portrait_item.ml'), 'utf8')
    const empty = source.slice(source.indexOf('let empty_id ='), source.indexOf('let id ='))
    const items = source.slice(source.indexOf('let id ='), source.indexOf('let of_id'))
    for (const [slot, ids] of Object.entries(EQUIPMENT_IDS)) {
      const constructor = slot[0]!.toUpperCase() + slot.slice(1)
      const bare = empty.match(new RegExp(`\\| ${constructor} -> "([^"]+)"`))?.[1]
      expect(bare, `empty ${slot}`).toBeDefined()
      const values = [...items.matchAll(new RegExp(`\\| ${constructor}_item[^\\n]*-> "([^"]+)"`, 'g'))].map(match => match[1])
      expect(values.length).toBeGreaterThan(0)
      expect([...ids].sort()).toEqual([bare, ...values].sort())
    }
  })
})
