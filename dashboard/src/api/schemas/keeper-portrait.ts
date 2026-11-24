import { Schema } from '../../lib/wire-schema'
import { isKeeperPortraitReading, type KeeperPortraitReading } from '../../lib/keeper-portrait'
export * from '../../lib/keeper-portrait'

export const KeeperPortraitSchema: Schema.Schema<KeeperPortraitReading> = Schema.declare(isKeeperPortraitReading)
