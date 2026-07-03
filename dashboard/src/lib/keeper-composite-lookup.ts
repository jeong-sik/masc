import type { Keeper } from '../types'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'

/**
 * Resolve the composite snapshot for a keeper from the fleet-wide
 * by-key map built by `composite-signals.buildCompositeByKeeperKey`.
 *
 * The map is keyed by the backend keeper name and correlation_id
 * (`keeper_composite_observer.ml` `snapshot_to_json`), while a roster
 * `Keeper` row carries the registry `name` plus an optional `keeper_id`,
 * so both keys are tried.
 *
 * This is the single source of truth for "which composite snapshot
 * belongs to this keeper" — shared by the agent roster and the IDE
 * keeper work panel so the two views cannot drift onto different
 * resolution rules (task-1740, IDE Observation Plane v2 axis C3).
 */
export function compositeSnapshotForKeeper(
  keeper: Keeper | null | undefined,
  compositeByKeeperKey: ReadonlyMap<string, KeeperCompositeSnapshot> | null,
): KeeperCompositeSnapshot | null {
  if (!keeper || !compositeByKeeperKey) return null
  return (
    compositeByKeeperKey.get(keeper.name)
    ?? (typeof keeper.keeper_id === 'string'
      ? compositeByKeeperKey.get(keeper.keeper_id) ?? null
      : null)
  )
}
