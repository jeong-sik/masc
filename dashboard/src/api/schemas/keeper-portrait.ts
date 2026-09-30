import { Schema } from 'effect'
import { EQUIPMENT_IDS, type KeeperEquipment, type KeeperPortraitReading } from '../../lib/keeper-portrait'
export * from '../../lib/keeper-portrait'

export const KeeperEquipmentSchema: Schema.Schema<KeeperEquipment> = Schema.Struct({
  face: Schema.Literal(...EQUIPMENT_IDS.face),
  neck: Schema.Literal(...EQUIPMENT_IDS.neck),
  head: Schema.Literal(...EQUIPMENT_IDS.head),
  hand: Schema.Literal(...EQUIPMENT_IDS.hand),
  base: Schema.Literal(...EQUIPMENT_IDS.base),
})
export const KeeperPortraitSchema: Schema.Schema<KeeperPortraitReading> = Schema.Union(
  Schema.Struct({ state: Schema.Literal('ready'), equipment: KeeperEquipmentSchema }),
  Schema.Struct({ state: Schema.Literal('unavailable'), reason: Schema.String.pipe(Schema.filter(value => value.trim().length > 0)) }),
)
