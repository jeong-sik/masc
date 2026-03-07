import type { TabId } from '../types'

export type DashboardNavGroup = 'observe' | 'coordinate' | 'command'

export interface DashboardNavItem {
  id: TabId
  label: string
  icon: string
  group: DashboardNavGroup
  description: string
}

export interface DashboardNavSection {
  id: DashboardNavGroup
  label: string
  description: string
}

export const DASHBOARD_NAV_SECTIONS: DashboardNavSection[] = [
  {
    id: 'observe',
    label: 'Observe',
    description: 'Live health, execution state, and room-wide telemetry',
  },
  {
    id: 'coordinate',
    label: 'Coordinate',
    description: 'Conversation, decisions, planning, and backlog context',
  },
  {
    id: 'command',
    label: 'Command',
    description: 'Direct control surfaces and intervention workflows',
  },
]

// Primary IA for the side rail navigation.
export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  {
    id: 'command',
    label: 'Command',
    icon: '\uD83E\uDDED',
    group: 'command',
    description: 'Company, platoon, squad, and agent command plane with operation and trace visibility',
  },
  {
    id: 'overview',
    label: 'Overview',
    icon: '\uD83C\uDFE0',
    group: 'observe',
    description: 'Room health, keeper pressure, and top-line execution status',
  },
  {
    id: 'agents',
    label: 'Agents',
    icon: '\uD83E\uDD16',
    group: 'observe',
    description: 'Live monitor for agent status, keeper pressure, and current execution focus',
  },
  {
    id: 'board',
    label: 'Board',
    icon: '\uD83D\uDCAC',
    group: 'coordinate',
    description: 'Human and agent discussion feed with system noise filtered by default',
  },
  {
    id: 'goals',
    label: 'Planning',
    icon: '\uD83C\uDFAF',
    group: 'coordinate',
    description: 'Goals, MDAL loops, and task backlog in one planning surface',
  },
  {
    id: 'ops',
    label: 'Ops',
    icon: '\uD83C\uDFAE',
    group: 'command',
    description: 'Guided operator controls for room, sessions, and keepers',
  },
  {
    id: 'trpg',
    label: 'TRPG',
    icon: '\u2694\uFE0F',
    group: 'command',
    description: 'Narrative room control and state visibility',
  },
]
