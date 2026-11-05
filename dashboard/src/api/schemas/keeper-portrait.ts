import { Schema } from 'effect'
import { isKeeperPortraitReading, type KeeperPortraitReading } from '../../lib/keeper-portrait'
export * from '../../lib/keeper-portrait'

export const KeeperPortraitSchema: Schema.Schema<KeeperPortraitReading> = Schema.declare(isKeeperPortraitReading)
