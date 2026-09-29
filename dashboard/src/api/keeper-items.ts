import { apiRequestErrorFromResponse, authHeaders, fetchWithTimeout } from './core'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'
import { EQUIPMENT_IDS, type KeeperEquipment } from './schemas/keeper-portrait'

export type ItemSlot = keyof KeeperEquipment
export type KeeperItem = { id: string; slot: ItemSlot; priceMilli: string | null }
export type KeeperItemsReading =
  | { status: 'off'; keeper: string }
  | { status: 'disabled'; keeper: string; reason: string }
  | { status: 'ready'; keeper: string; balanceMilli: string; ownedItems: string[]; catalog: KeeperItem[] }

const slots: ItemSlot[] = ['face', 'neck', 'head', 'hand', 'base']
const itemSlot = new Map<string, ItemSlot>(
  slots.flatMap(slot => EQUIPMENT_IDS[slot].slice(1).map(id => [id, slot] as const)),
)

function record(value: unknown, keys: string[]): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid Item account object')
  const fields = value as Record<string, unknown>
  if (Object.keys(fields).sort().join(',') !== [...keys].sort().join(',')) throw new Error('Invalid Item account fields')
  return fields
}

function canonicalAmount(value: unknown): string {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) throw new Error('Invalid Item amount')
  return value
}

function catalogEntry(value: unknown): KeeperItem {
  const candidate = value as Record<string, unknown> | null
  const priced = candidate?.price_status === 'priced'
  const entry = record(value, priced ? ['id', 'slot', 'price_status', 'price_milli'] : ['id', 'slot', 'price_status'])
  const slot = itemSlot.get(String(entry.id))
  if (slot === undefined || entry.slot !== slot) throw new Error('Invalid Item catalog entry')
  if (entry.price_status !== 'priced' && entry.price_status !== 'unpriced') throw new Error('Invalid Item price status')
  return { id: entry.id as string, slot, priceMilli: priced ? canonicalAmount(entry.price_milli) : null }
}

export function parseKeeperItems(value: unknown, keeper: string): KeeperItemsReading {
  const candidate = value as Record<string, unknown> | null
  const status = candidate?.status
  const keys = status === 'off' ? ['status', 'keeper']
    : status === 'disabled' ? ['status', 'keeper', 'reason']
    : status === 'ready' ? ['status', 'keeper', 'balance_milli', 'owned_items', 'catalog']
    : []
  const fields = record(value, keys)
  if (fields.keeper !== keeper) throw new Error('Item account Keeper mismatch')
  if (status === 'off') return { status, keeper }
  if (status === 'disabled') {
    if (typeof fields.reason !== 'string' || fields.reason.trim() === '') throw new Error('Invalid Item disabled reason')
    return { status, keeper, reason: fields.reason }
  }
  if (status !== 'ready' || !Array.isArray(fields.owned_items) || !Array.isArray(fields.catalog)) {
    throw new Error('Invalid Item account')
  }
  const catalog = fields.catalog.map(catalogEntry)
  const catalogIds = catalog.map(entry => entry.id)
  if (new Set(catalogIds).size !== itemSlot.size || catalogIds.length !== itemSlot.size ||
      catalogIds.some(id => !itemSlot.has(id))) throw new Error('Incomplete Item catalog')
  const ownedItems = fields.owned_items
  if (ownedItems.some(id => typeof id !== 'string' || !itemSlot.has(id)) ||
      new Set(ownedItems).size !== ownedItems.length) throw new Error('Invalid owned Items')
  return { status, keeper, balanceMilli: canonicalAmount(fields.balance_milli), ownedItems, catalog }
}

export async function fetchKeeperItems(keeper: string, signal?: AbortSignal): Promise<KeeperItemsReading> {
  const path = `/api/v1/keepers/${encodeURIComponent(keeper)}/items`
  return fetchWithTimeout(path, { headers: authHeaders(), signal, cache: 'no-cache' }, DEFAULT_GET_TIMEOUT_MS, async response => {
    if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
    return parseKeeperItems(await response.json(), keeper)
  })
}
