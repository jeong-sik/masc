// Keeper roster view preferences. They live apart from the roster component so
// a surface outside the lazily loaded keepers tab (the top bar's attention
// chips) can set the filter without loading the roster.

import { persistentSignal } from '../../lib/persistent-signal'

export type RosterFilter = 'all' | 'run' | 'att'
export type RosterSort = 'status' | 'recent' | 'name' | 'att'

const ROSTER_FILTER_VALUES: readonly RosterFilter[] = ['all', 'run', 'att']
const ROSTER_SORT_VALUES: readonly RosterSort[] = ['status', 'recent', 'name', 'att']

function memberOr<T extends string>(allowed: readonly T[], fallback: T): (raw: string) => T {
  return raw => {
    const parsed: unknown = JSON.parse(raw)
    return typeof parsed === 'string' && (allowed as readonly string[]).includes(parsed)
      ? (parsed as T)
      : fallback
  }
}

// View preferences survive reload (persistentSignal SSOT). Previously
// component-local useState: every remount snapped back to all/최근순.
export const rosterFilterPref = persistentSignal<RosterFilter>({
  key: 'dashboard:kw-roster:filter-v1',
  defaultValue: 'all',
  deserialize: memberOr(ROSTER_FILTER_VALUES, 'all'),
})
// The standalone's default is lifecycle grouping: 실행 중, 확인 필요,
// 일시정지, then 중지. Recency remains available as an explicit operator
// preference.
export const rosterSortPref = persistentSignal<RosterSort>({
  key: 'dashboard:kw-roster:sort-v1',
  defaultValue: 'status',
  deserialize: memberOr(ROSTER_SORT_VALUES, 'status'),
})
