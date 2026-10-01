import { describe, expect, it } from 'vitest'
import { EQUIPMENT_IDS } from './schemas/keeper-portrait'
import { parseKeeperItems } from './keeper-items'

const catalog = Object.entries(EQUIPMENT_IDS).flatMap(([slot, ids]) =>
  ids.slice(1).map(id => ({ id, slot, price_status: id === 'crown' ? 'priced' : 'unpriced', ...(id === 'crown' ? { price_milli: '200' } : {}) })),
)
const ready = { status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog }

describe('Keeper Item account wire', () => {
  it('decodes all three states and keeps unpriced separate from zero', () => {
    expect(parseKeeperItems({ status: 'off', keeper: 'rondo' }, 'rondo').status).toBe('off')
    expect(parseKeeperItems({ status: 'disabled', keeper: 'rondo', reason: 'bad policy' }, 'rondo').status).toBe('disabled')
    const parsed = parseKeeperItems(ready, 'rondo')
    expect(parsed.status).toBe('ready')
    if (parsed.status !== 'ready') throw new Error('Expected ready account')
    expect(parsed.balance_milli).toBe('800')
    expect(parsed.catalog.find(item => item.id === 'crown')).toMatchObject({ price_milli: '200' })
    expect(parsed.catalog.find(item => item.id === 'book')).toMatchObject({ price_status: 'unpriced' })
  })

  it.each(['\n', '\r', '\r\n', '\u2028', '\u2029'])(
    'rejects trailing line terminator %j in balances and prices',
    terminator => {
      const balanceWire = JSON.parse(JSON.stringify({ ...ready, balance_milli: `800${terminator}` }))
      const priceWire = JSON.parse(JSON.stringify({ ...ready,
        catalog: catalog.map(item => item.id === 'crown' ? { ...item, price_milli: `200${terminator}` } : item),
      }))
      expect(() => parseKeeperItems(balanceWire, 'rondo')).toThrow('schema drift')
      expect(() => parseKeeperItems(priceWire, 'rondo')).toThrow('schema drift')
    },
  )

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
    expect(() => parseKeeperItems({ status: 'disabled', keeper: 'rondo', reason: ' ' }, 'rondo')).toThrow()
  })
})
