import { describe, expect, it } from 'vitest'
import { EQUIPMENT_IDS } from './schemas/keeper-portrait'
import { parseKeeperItems } from './keeper-items'

const catalog = Object.entries(EQUIPMENT_IDS).flatMap(([slot, ids]) =>
  ids.slice(1).map(id => ({ id, slot, price_status: id === 'crown' ? 'priced' : 'unpriced', ...(id === 'crown' ? { price_milli: '200' } : {}) })),
)
const ready = { status: 'ready', account_revision: 'a'.repeat(64), keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog }

describe('Keeper Item account wire', () => {
  it('decodes all three states and keeps unpriced separate from zero', () => {
    expect(parseKeeperItems({ status: 'off', account_revision: null, keeper: 'rondo' }, 'rondo').status).toBe('off')
    expect(parseKeeperItems({ status: 'disabled', account_revision: 'a'.repeat(64), keeper: 'rondo', reason: 'bad policy' }, 'rondo').status).toBe('disabled')
    const parsed = parseKeeperItems(ready, 'rondo')
    expect(parsed.status).toBe('ready')
    if (parsed.status !== 'ready') throw new Error('Expected ready account')
    expect(parsed.balance_milli).toBe('800')
    expect(parsed.catalog.find(item => item.id === 'crown')).toMatchObject({ price_milli: '200' })
    expect(parsed.catalog.find(item => item.id === 'book')).toMatchObject({ price_status: 'unpriced' })
  })

  it('rejects a different Keeper, incomplete catalog, duplicate ownership and malformed price', () => {
    expect(() => parseKeeperItems(ready, 'geek-scout')).toThrow()
    expect(() => parseKeeperItems({ ...ready, catalog: catalog.slice(1) }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ ...ready, catalog: catalog.map(item => item.id === 'crown' ? { ...item, slot: 'face' } : item) }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ ...ready, catalog: catalog.map(item => item.id === 'crown' ? { ...item, extra: true } : item) }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ ...ready, owned_items: ['crown', 'crown'] }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ ...ready, catalog: catalog.map(item => item.id === 'crown' ? { ...item, price_milli: '-1' } : item) }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ ...ready, balance_milli: 800 }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ ...ready, balance_milli: '0800' }, 'rondo')).toThrow()
    expect(parseKeeperItems({ ...ready, balance_milli: '9007199254740993' }, 'rondo')).toMatchObject({ balance_milli: '9007199254740993' })
    expect(() => parseKeeperItems({ ...ready, extra: true }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ status: 'disabled', account_revision: 'a'.repeat(64), keeper: 'rondo', reason: ' ' }, 'rondo')).toThrow()
  })
  it('requires a canonical revision matching the observed status', () => {
    for (const invalid of [undefined, null, '', 'A'.repeat(64), 'a'.repeat(63), 1]) {
      expect(() => parseKeeperItems({ ...ready, account_revision: invalid }, 'rondo')).toThrow()
    }
    expect(() => parseKeeperItems({ status: 'off', keeper: 'rondo' }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ status: 'off', account_revision: 'a'.repeat(64), keeper: 'rondo' }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ status: 'disabled', account_revision: null, keeper: 'rondo', reason: 'unread' }, 'rondo')).toThrow()
  })

})
