/**
 * DashboardSurface — read-model envelope for the MASC dashboard.
 *
 * Instead of passing raw `KeeperRuntimeProjection` or `KeeperMonitoringSummary`
 * directly to UI components, every surface tunnel goes through this single
 * typed envelope.  Benefits:
 *
 *  1. **Stable API boundary** — consumers import from one module; internal
 *     projection types can evolve without touching every component.
 *  2. **Version tag** — a `surfaceVersion` discriminator lets future
 *     migrations (e.g. schema v2) coexist with older surfaces.
 *  3. **Derived metadata** — `assembledAt`, `keeperCount`, and
 *     `monitoringSummary` are computed once at assembly time rather than
 *     re-derived per component.
 *
 * @see https://github.com/keeper/masc-mcp/issues/16081
 */

import type { Keeper } from '../types'
import type { KeeperRuntimeProjection } from './keeper-runtime-projection'
import type { KeeperMonitoringSummary } from './monitoring-runtime'

// ── surface version ────────────────────────────────────────────────
export const DASHBOARD_SURFACE_VERSION = 1

// ── envelope types ─────────────────────────────────────────────────

export interface KeeperSurfaceEntry {
  /** Keeper identity (stable across generations). */
  readonly keeper: Keeper
  /** Derived runtime projection (operational state, signals, etc.). */
  readonly runtime: KeeperRuntimeProjection
  /** Coarse-grained monitoring summary for band/phase/stage views. */
  readonly monitoring: KeeperMonitoringSummary
}

export interface DashboardSurfaceMeta {
  /** Surface schema version — bump when the shape changes incompatibly. */
  readonly surfaceVersion: number
  /** ISO-8601 timestamp when this snapshot was assembled. */
  readonly assembledAt: string
}

export interface DashboardSurface {
  readonly meta: DashboardSurfaceMeta
  /** All keepers keyed by their canonical name for O(1) lookup. */
  readonly keepers: ReadonlyMap<string, KeeperSurfaceEntry>
  /** Convenience: same data as an array for iteration. */
  readonly keeperList: ReadonlyArray<KeeperSurfaceEntry>
  /** Aggregate counts. */
  readonly counts: DashboardSurfaceCounts
  /** Pre-computed monitoring summaries keyed by band. */
  readonly bands: ReadonlyMap<string, ReadonlyArray<KeeperSurfaceEntry>>
}

export interface DashboardSurfaceCounts {
  readonly total: number
  readonly active: number
  readonly attention: number
  readonly paused: number
  readonly offline: number
}

// ── assembly ───────────────────────────────────────────────────────

/** Collect per-band lists for fast filter-free rendering. */
function groupByBand(
  entries: ReadonlyArray<KeeperSurfaceEntry>,
): ReadonlyMap<string, ReadonlyArray<KeeperSurfaceEntry>> {
  const map = new Map<string, KeeperSurfaceEntry[]>()
  for (const entry of entries) {
    const band = entry.monitoring.band.key
    let list = map.get(band)
    if (!list) {
      list = []
      map.set(band, list)
    }
    list.push(entry)
  }
  // freeze inner arrays for deep immutability
  for (const [k, v] of map) {
    map.set(k, Object.freeze([...v]))
  }
  return map
}

function deriveCounts(
  entries: ReadonlyArray<KeeperSurfaceEntry>,
): DashboardSurfaceCounts {
  let active = 0
  let attention = 0
  let paused = 0
  let offline = 0
  for (const entry of entries) {
    switch (entry.monitoring.band.key) {
      case 'active':
        active++
        break
      case 'attention':
        attention++
        break
      case 'paused':
        paused++
        break
      case 'offline':
        offline++
        break
    }
  }
  return {
    total: entries.length,
    active,
    attention,
    paused,
    offline,
  } as const
}

export function assembleDashboardSurface(
  entries: ReadonlyArray<KeeperSurfaceEntry>,
): DashboardSurface {
  const frozen = Object.freeze([...entries])
  const keeperMap = new Map<string, KeeperSurfaceEntry>()
  for (const entry of frozen) {
    keeperMap.set(entry.keeper.name, entry)
  }

  const meta: DashboardSurfaceMeta = {
    surfaceVersion: DASHBOARD_SURFACE_VERSION,
    assembledAt: new Date().toISOString(),
  }

  return {
    meta,
    keepers: keeperMap,
    keeperList: frozen,
    counts: deriveCounts(frozen),
    bands: groupByBand(frozen),
  }
}