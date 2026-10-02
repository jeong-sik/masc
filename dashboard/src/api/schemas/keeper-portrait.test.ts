import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { Either, Schema } from 'effect'
import { KeeperPortraitSchema, EQUIPMENT_IDS, isKeeperPortraitReading, keeperEquipmentKey, readKeeperPortrait } from './keeper-portrait'

const equipment = { face: 'bare_face', neck: 'bare_neck', head: 'bare_head', hand: 'empty_hand', base: 'no_dish' } as const

describe('server portrait snapshots', () => {
  it('keeps the initial-store reader consistent with the feature schema', () => {
    const inputs: unknown[] = [undefined, null, [], {},
      { state: 'ready', equipment }, { state: 'ready', equipment, extra: true },
      { state: 'unavailable', reason: 'ledger unreadable' },
      { state: 'unavailable', reason: ' ' },
      { state: 'unavailable', reason: 'ledger unreadable', equipment }]
    for (const [slot, ids] of Object.entries(EQUIPMENT_IDS)) {
      for (const id of ids) inputs.push({ state: 'ready', equipment: { ...equipment, [slot]: id } })
      for (const bad of [undefined, null, 1, 'unknown']) {
        inputs.push({ state: 'ready', equipment: { ...equipment, [slot]: bad } })
      }
    }
    inputs.push({ state: 'ready', equipment: { ...equipment, extra: 'crown' } })
    for (const value of inputs) {
      const schema = Schema.decodeUnknownEither(KeeperPortraitSchema, { onExcessProperty: 'error' })(value)
      const reading = readKeeperPortrait(value)
      if (Either.isRight(schema)) expect(reading).toEqual(schema.right)
      else expect(reading).toEqual({ state: 'unavailable', reason: 'Portrait observation missing or malformed' })
    }
  })
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

  it('distinguishes producer unavailability from malformed or excess wire data', () => {
    const unavailable = { state: 'unavailable', reason: 'ledger unreadable: permission denied' }
    expect(isKeeperPortraitReading(unavailable)).toBe(true)
    expect(readKeeperPortrait(unavailable)).toEqual(unavailable)
    for (const raw of [{ state: 'ready', equipment, extra: true }, { ...unavailable, extra: true },
      { state: 'unavailable' }, { state: 'unavailable', reason: 0 }, { state: 'unknown', equipment }]) {
      expect(isKeeperPortraitReading(raw)).toBe(false)
      expect(readKeeperPortrait(raw)).toEqual({ state: 'unavailable', reason: 'Portrait observation missing or malformed' })
    }
    for (const slot of Object.keys(EQUIPMENT_IDS)) {
      const incomplete: Record<string, unknown> = { ...equipment }
      delete incomplete[slot]
      expect(isKeeperPortraitReading({ state: 'ready', equipment: incomplete })).toBe(false)
    }
  })

  it('keeps the observed outfit immutable and detached from later raw mutations', () => {
    const wireEquipment = { ...equipment, head: 'crown' }
    const reading = readKeeperPortrait({ state: 'ready', equipment: wireEquipment })
    wireEquipment.head = 'beanie'
    expect(reading).toEqual({ state: 'ready', equipment: { ...equipment, head: 'crown' } })
    if (reading.state !== 'ready') throw new Error('Expected a valid observed outfit')
    expect(Object.isFrozen(reading)).toBe(true)
    expect(Object.isFrozen(reading.equipment)).toBe(true)
  })

})
