import type { BoardAudience, Keeper, KeeperBoardAddress } from '../types'
import { isRecord } from '../components/common/normalize'

function onlyKeys(raw: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(raw).length === keys.length && keys.every(key => Object.hasOwn(raw, key))
}

// Keeper_identity.Keeper_id uses String.lowercase_ascii, including for an
// explicitly configured address. Keep non-ASCII bytes unchanged as it does.
function canonicalKeeperId(value: string): string {
  return value.trim().replace(/[A-Z]/g, letter => letter.toLowerCase())
}

// Board.Agent_id delegates to Validation.Id_shape: ASCII shape, 64 bytes,
// optional namespace colon, no leading dot. This decodes the wire identity;
// it does not reparse body text or resolve a Keeper alias.
function isBoardTarget(raw: unknown): raw is string {
  return typeof raw === 'string' && raw.length > 0 && raw.length <= 64
    && raw.trim() === raw && !raw.startsWith('.')
    && /^[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+)?$/.test(raw)
}

export function readBoardAudience(raw: unknown): BoardAudience {
  if (raw == null) return { kind: 'unavailable', reason: 'not_recorded' }
  if (isRecord(raw)) {
    if (raw.kind === 'targets' && onlyKeys(raw, ['kind', 'targets'])
      && Array.isArray(raw.targets) && raw.targets.length > 0
      && raw.targets.every(isBoardTarget)
      && new Set(raw.targets).size === raw.targets.length) {
      return { kind: 'targets', targets: [...raw.targets] }
    }
    // Local canonical readings can pass through both direct Board and
    // dashboard/bootstrap consumers. An unavailable reading grants no target.
    if (raw.kind === 'unavailable' && onlyKeys(raw, ['kind', 'reason'])
      && (raw.reason === 'not_recorded' || raw.reason === 'invalid_payload')) {
      return { kind: 'unavailable', reason: raw.reason }
    }
    if ((raw.kind === 'broadcast' || raw.kind === 'thread_participants' || raw.kind === 'discoverable')
      && onlyKeys(raw, ['kind'])) return { kind: raw.kind }
  }
  return { kind: 'unavailable', reason: 'invalid_payload' }
}

export function readKeeperBoardAddress(raw: unknown): KeeperBoardAddress {
  if (raw == null) return { state: 'unavailable', reason: 'not_reported' }
  if (isRecord(raw)) {
    if (raw.state === 'ready' && onlyKeys(raw, ['state', 'target_ids'])
      && Array.isArray(raw.target_ids)
      && raw.target_ids.every((id): id is string => typeof id === 'string' && id.length > 0
        && id.trim() === id && canonicalKeeperId(id) === id)
      && new Set(raw.target_ids).size === raw.target_ids.length) {
      return { state: 'ready', target_ids: [...raw.target_ids] }
    }
    if (raw.state === 'unavailable' && onlyKeys(raw, ['state', 'reason'])
      && (raw.reason === 'metadata_absent' || raw.reason === 'effective_metadata_unread')) {
      return { state: 'unavailable', reason: raw.reason }
    }
  }
  return { state: 'unavailable', reason: 'invalid_payload' }
}

export interface BoardTargetReading {
  target: string
  keepers: string[]
  unresolved: boolean
}

/** This compares the stored audience with the current address projection. It
 * does not parse Markdown or infer aliases from a Keeper's display name.
 * Keeper_id's only identity fold is trim + lowercase, not prefix recovery. */
export function boardTargetReadings(audience: BoardAudience, keepers: Keeper[]): BoardTargetReading[] {
  if (audience.kind !== 'targets') return []
  const unresolved = keepers.length === 0 || keepers.some(keeper => keeper.board_address?.state !== 'ready')
  return audience.targets.map(target => ({
    target,
    keepers: keepers.filter(keeper => keeper.board_address?.state === 'ready'
      && keeper.board_address.target_ids.includes(canonicalKeeperId(target)))
      .map(keeper => keeper.name),
    unresolved,
  }))
}
