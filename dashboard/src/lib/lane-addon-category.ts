import { LANE_ADDON_CATEGORIES, type LaneAddonCategory } from '../api/lane-addon-category'
import type { LaneInventoryRow } from '../api/lane-inventory'
import type { LaneAddonInstance, LaneAddonSnapshot } from '../api/lane-addons'

export const laneAddonCategoryLabels: Record<LaneAddonCategory, string> = {
  memory_judgment: '기억·판단', browser: '브라우저', external_communications: '외부 소통',
  voice_media: '음성·미디어', execution_environment: '실행 환경', analysis: '분석',
}
export type AddonCategoryGroup = LaneAddonCategory | 'unclassified' | 'unavailable'
export type AddonCategoryFilter = 'all' | AddonCategoryGroup
export const addonCategoryGroups: readonly AddonCategoryGroup[] = [
  ...LANE_ADDON_CATEGORIES, 'unclassified', 'unavailable',
]
export function categoryGroup(category: LaneAddonCategory | undefined): AddonCategoryGroup {
  return category === undefined ? 'unclassified' : category
}
export function categoryLabel(group: AddonCategoryGroup): string {
  switch (group) {
    case 'unclassified': return '미분류'
    case 'unavailable': return '범주 확인 필요'
    default: return laneAddonCategoryLabels[group]
  }
}

/** A current declaration never inherits the category of an older worker. */
export function inventoryCategory(row: LaneInventoryRow): AddonCategoryGroup {
  switch (row.state.kind) {
    case 'browser_clients': case 'browser_executor': case 'machine': case 'exact':
      return categoryGroup(row.ui_category)
    case 'package': break
  }
  const declaration = row.state.declaration
  if (declaration?.kind === 'valid') return categoryGroup(declaration.ui_category)
  if (declaration !== null) return 'unavailable'
  // Manual workers have no current declaration; this is their original package.
  const [original] = row.state.instances
  return original ? categoryGroup(original.ui_category) : 'unavailable'
}

/** Live managed workers join the exact current id and file. Retained/manual
 * instances describe their original package, never today's installation. */
export function workerCategory(snapshot: LaneAddonSnapshot, instance: LaneAddonInstance): AddonCategoryGroup {
  const owner = instance.configuration
  if (instance.runtime_presence === 'retained' || owner === null) return categoryGroup(instance.package.ui_category)
  const configuration = snapshot.configuration
  if (configuration === null || !configuration.complete) return 'unavailable'
  const matches = configuration.declarations.filter(declaration => declaration.id === owner.id
    || declaration.source_path === owner.source_path)
  const [current] = matches
  if (matches.length !== 1 || current?.id !== owner.id || current.source_path !== owner.source_path
    || configuration.issues.some(issue => issue.id === owner.id || issue.source_path === owner.source_path
      || issue.source_path === configuration.directory)) return 'unavailable'
  return categoryGroup(current.ui_category)
}

/** Keep original item references and identities; grouping is never a selection. */
export function groupAddonCategories<T>(items: readonly T[], category: (item: T) => AddonCategoryGroup,
  filter: AddonCategoryFilter = 'all'): { category: AddonCategoryGroup; items: T[] }[] {
  return addonCategoryGroups.flatMap(group => {
    if (filter !== 'all' && filter !== group) return []
    const members = items.filter(item => category(item) === group)
    return members.length ? [{ category: group, items: members }] : []
  })
}
