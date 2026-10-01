import { Schema } from 'effect'
import { isKeeperEquipment, isKeeperPortraitReading, type KeeperEquipment, type KeeperPortraitReading } from '../../lib/keeper-portrait'
export * from '../../lib/keeper-portrait'

export const KeeperEquipmentSchema: Schema.Schema<KeeperEquipment> = Schema.declare(isKeeperEquipment)
export const KeeperPortraitSchema: Schema.Schema<KeeperPortraitReading> = Schema.declare(isKeeperPortraitReading)
