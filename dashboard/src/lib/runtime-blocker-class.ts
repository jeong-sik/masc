import { KEEPER_RUNTIME_BLOCKER_CLASSES, type KeeperRuntimeBlockerClass } from '../types'

const RUNTIME_BLOCKER_CLASS_SET: ReadonlySet<string> = new Set(
  KEEPER_RUNTIME_BLOCKER_CLASSES,
)

export function isKeeperRuntimeBlockerClass(
  value: string,
): value is KeeperRuntimeBlockerClass {
  return RUNTIME_BLOCKER_CLASS_SET.has(value)
}

export function asKeeperRuntimeBlockerClass(
  value: unknown,
): KeeperRuntimeBlockerClass | null {
  if (typeof value !== 'string') return null
  return isKeeperRuntimeBlockerClass(value) ? value : null
}
