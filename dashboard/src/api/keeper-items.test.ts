import { afterEach, describe, expect, it, vi } from 'vitest'
import { EQUIPMENT_IDS } from './schemas/keeper-portrait'
import { fetchKeeperItems, parseKeeperItems } from './keeper-items'

const revision = 'a'.repeat(64)
const catalog = Object.entries(EQUIPMENT_IDS).flatMap(([slot, ids]) =>
  ids.slice(1).map(id => ({ id, slot, price_status: id === 'crown' ? 'priced' : 'unpriced', ...(id === 'crown' ? { price_milli: '200' } : {}) })),
)
const ready = { status: 'ready', account_revision: revision, keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog }

describe('Keeper Item account wire', () => {
  it('decodes all three states and keeps unpriced separate from zero', () => {
    expect(parseKeeperItems({ status: 'off', account_revision: null, keeper: 'rondo' }, 'rondo').status).toBe('off')
    expect(parseKeeperItems({ status: 'disabled', account_revision: revision, keeper: 'rondo', reason: 'bad policy' }, 'rondo').status).toBe('disabled')
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
    expect(() => parseKeeperItems({ status: 'disabled', account_revision: revision, keeper: 'rondo', reason: ' ' }, 'rondo')).toThrow()
  })

  it('requires actual revision bytes for ready/disabled and explicit null for off', () => {
    const { account_revision: _, ...missing } = ready
    expect(() => parseKeeperItems(missing, 'rondo')).toThrow()
    for (const value of [null, '', 'a'.repeat(63), 'A'.repeat(64), `${revision}\n`, 42]) {
      expect(() => parseKeeperItems({ ...ready, account_revision: value }, 'rondo')).toThrow()
      expect(() => parseKeeperItems({ status: 'disabled', keeper: 'rondo', reason: 'bad policy', account_revision: value }, 'rondo')).toThrow()
    }
    expect(() => parseKeeperItems({ status: 'off', keeper: 'rondo' }, 'rondo')).toThrow()
    expect(() => parseKeeperItems({ status: 'off', keeper: 'rondo', account_revision: revision }, 'rondo')).toThrow()
    // Wire parsing describes actual B; the panel owns expectation A and publication.
    expect(parseKeeperItems({ ...ready, account_revision: 'b'.repeat(64) }, 'rondo').account_revision).toBe('b'.repeat(64))
  })

  it('rejects line-terminated monetary bytes in both the wallet and priced catalog', () => {
    for (const ending of ['\n', '\r', '\r\n', '\u2028', '\u2029']) {
      const amount = `200${ending}`
      expect(() => parseKeeperItems({ ...ready, balance_milli: amount }, 'rondo')).toThrow('Keeper Item account schema drift')
      expect(() => parseKeeperItems({ ...ready,
        catalog: catalog.map(item => item.id === 'crown' ? { ...item, price_milli: amount } : item),
      }, 'rondo')).toThrow('Keeper Item account schema drift')
    }
  })

  it('keeps explicit zero priced and preserves canonical wallet and price amounts beyond machine integers', () => {
    for (const amount of ['0', '18446744073709551614000']) {
      const parsed = parseKeeperItems({ ...ready, balance_milli: amount,
        catalog: catalog.map(item => item.id === 'crown' ? { ...item, price_milli: amount } : item),
      }, 'rondo')
      if (parsed.status !== 'ready') throw new Error('Expected ready account')
      expect(parsed.balance_milli).toBe(amount)
      const crown = parsed.catalog.find(item => item.id === 'crown')
      if (!crown || crown.price_status !== 'priced') throw new Error('Expected an explicitly priced crown')
      expect(crown.price_milli).toBe(amount)
      expect(parsed.catalog.find(item => item.id === 'book')).toMatchObject({ price_status: 'unpriced' })
    }
  })
})

afterEach(() => vi.unstubAllGlobals())

describe('Keeper Item request workspace authority', () => {
  it('sends the captured canonical workspace even before a replacement is observed', async () => {
    const expected = '/captured/workspace A & exact'
    const server = '/replacement/workspace B'
    const fetch = vi.fn(async (input: string) => {
      const request = new URL(input, 'http://fixture.invalid')
      expect(request.pathname).toBe('/api/v1/keepers/rondo/items')
      expect(request.searchParams.get('expected_workspace')).toBe(expected)
      return new Response(JSON.stringify({ error: 'Server workspace changed' }), {
        status: request.searchParams.get('expected_workspace') === server ? 200 : 409,
        headers: { 'content-type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', fetch)
    await expect(fetchKeeperItems('rondo', expected)).rejects.toMatchObject({ status: 409 })
    expect(fetch).toHaveBeenCalledTimes(1)
  })
})
