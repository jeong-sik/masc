import { Either, Schema } from 'effect'
import { EQUIPMENT_IDS } from './keeper-portrait'
import { CandleAccountDigestSchema } from './candle-observation'

const slots = ['face', 'neck', 'head', 'hand', 'base'] as const
const itemSlot = new Map<string, typeof slots[number]>(
  slots.flatMap(slot => EQUIPMENT_IDS[slot].slice(1).map(id => [id, slot] as const)),
)
const AmountSchema = Schema.String.pipe(
  Schema.filter(value => /^(0|[1-9][0-9]*)$/.test(value) || 'Item amount must be canonical decimal'),
)
const ItemIdSchema = Schema.String.pipe(
  Schema.filter(value => itemSlot.has(value) || 'unknown Item id'),
)
const ItemSlotSchema = Schema.Literal(...slots)
const CatalogEntrySchema = Schema.Union(
  Schema.Struct({ id: ItemIdSchema, slot: ItemSlotSchema, price_status: Schema.Literal('unpriced') }),
  Schema.Struct({ id: ItemIdSchema, slot: ItemSlotSchema, price_status: Schema.Literal('priced'), price_milli: AmountSchema }),
).pipe(Schema.filter(entry => itemSlot.get(entry.id) === entry.slot || 'Item in wrong slot'))

const ReadySchema = Schema.Struct({
  status: Schema.Literal('ready'),
  account_revision: CandleAccountDigestSchema,
  keeper: Schema.NonEmptyString,
  balance_milli: AmountSchema,
  owned_items: Schema.Array(ItemIdSchema),
  catalog: Schema.Array(CatalogEntrySchema),
}).pipe(Schema.filter(account => {
  const catalogIds = account.catalog.map(entry => entry.id)
  return (catalogIds.length === itemSlot.size
    && new Set(catalogIds).size === itemSlot.size
    && account.owned_items.length === new Set(account.owned_items).size)
    || 'Item catalog is incomplete or ownership is duplicated'
}))

export const KeeperItemsSchema = Schema.Union(
  Schema.Struct({ status: Schema.Literal('off'), keeper: Schema.NonEmptyString, account_revision: Schema.Null }),
  Schema.Struct({ status: Schema.Literal('disabled'), keeper: Schema.NonEmptyString, account_revision: CandleAccountDigestSchema,
    reason: Schema.String.pipe(Schema.filter(value => value.trim().length > 0 || 'disabled reason is empty')) }),
  ReadySchema,
)
export type KeeperItemsReading = Schema.Schema.Type<typeof KeeperItemsSchema>

export function parseKeeperItems(value: unknown, keeper: string): KeeperItemsReading {
  const parsed = Schema.decodeUnknownEither(KeeperItemsSchema, { onExcessProperty: 'error' })(value)
  if (Either.isLeft(parsed)) throw new Error('Keeper Item account schema drift')
  if (parsed.right.keeper !== keeper) throw new Error('Item account Keeper mismatch')
  return parsed.right
}
