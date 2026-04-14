// Observatory global filter — shared across surfaces (RFC-MASC-006 Phase 1)
//
// URL-synced reactive accessors (no separate signal store):
//   ?keeper=X     — keeper name filter
//   ?ns=Y         — namespace filter
//   ?op=Z         — operation_id filter
//   ?range=1h     — time range preset (5m, 1h, 24h, 7d)
//
// Consumers read `currentKeeperFilter()` etc. inside reactive scopes
// (components, effects, computeds) — the accessor reads `route.value`,
// which subscribes the enclosing reactive context to route changes.

import { route, navigate } from './router'

export type TimeRangePreset = '5m' | '1h' | '24h' | '7d'

export const TIME_RANGE_PRESETS: ReadonlyArray<TimeRangePreset> = ['5m', '1h', '24h', '7d']

const TIME_RANGE_LABELS: Record<TimeRangePreset, string> = {
  '5m': '최근 5분',
  '1h': '최근 1시간',
  '24h': '최근 24시간',
  '7d': '최근 7일',
}

export function timeRangeLabel(preset: TimeRangePreset): string {
  return TIME_RANGE_LABELS[preset]
}

// --- Reactive accessors (URL → state) ---

export function currentKeeperFilter(): string | null {
  const value = route.value.params.keeper
  return value && value.length > 0 ? value : null
}

export function currentNamespaceFilter(): string | null {
  const value = route.value.params.ns
  return value && value.length > 0 ? value : null
}

export function currentOperationFilter(): string | null {
  const value = route.value.params.op
  return value && value.length > 0 ? value : null
}

export function currentTimeRangeFilter(): TimeRangePreset | null {
  const value = route.value.params.range
  if (!value) return null
  return TIME_RANGE_PRESETS.includes(value as TimeRangePreset)
    ? (value as TimeRangePreset)
    : null
}

export function hasActiveObservatoryFilter(): boolean {
  return currentKeeperFilter() !== null
    || currentNamespaceFilter() !== null
    || currentOperationFilter() !== null
    || currentTimeRangeFilter() !== null
}

// --- Setters (state → URL) ---

type FilterPatch = {
  keeper?: string | null
  namespace?: string | null
  operation?: string | null
  range?: TimeRangePreset | null
}

export function setObservatoryFilter(patch: FilterPatch): void {
  const next: Record<string, string> = { ...route.value.params }

  if (patch.keeper !== undefined) {
    if (patch.keeper === null || patch.keeper === '') delete next.keeper
    else next.keeper = patch.keeper
  }
  if (patch.namespace !== undefined) {
    if (patch.namespace === null || patch.namespace === '') delete next.ns
    else next.ns = patch.namespace
  }
  if (patch.operation !== undefined) {
    if (patch.operation === null || patch.operation === '') delete next.op
    else next.op = patch.operation
  }
  if (patch.range !== undefined) {
    if (patch.range === null) delete next.range
    else next.range = patch.range
  }

  navigate(route.value.tab, next)
}

export function clearObservatoryFilters(): void {
  setObservatoryFilter({ keeper: null, namespace: null, operation: null, range: null })
}

export function setKeeperFilter(keeper: string | null): void {
  setObservatoryFilter({ keeper })
}

export function setTimeRangeFilter(range: TimeRangePreset | null): void {
  setObservatoryFilter({ range })
}
