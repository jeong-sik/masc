import type { TabId } from '../types'

export interface DashboardNavItem {
  id: TabId
  label: string
  icon: string
}

// Shared IA order for top nav and side rail.
export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  { id: 'overview', label: 'Overview', icon: '\uD83C\uDFE0' },
  { id: 'board', label: 'Board', icon: '\uD83D\uDCAC' },
  { id: 'activity', label: 'Activity', icon: '\uD83D\uDCCA' },
  { id: 'council', label: 'Council', icon: '\uD83C\uDFDB\uFE0F' },
  { id: 'goals', label: 'Planning', icon: '\uD83C\uDFAF' },
  { id: 'execution', label: 'Execution', icon: '\uD83D\uDEE0\uFE0F' },
  { id: 'tasks', label: 'Tasks', icon: '\uD83D\uDCCB' },
  { id: 'agents', label: 'Agents', icon: '\uD83E\uDD16' },
  { id: 'ops', label: 'Ops', icon: '\uD83C\uDFAE' },
  { id: 'trpg', label: 'TRPG', icon: '\u2694\uFE0F' },
]
