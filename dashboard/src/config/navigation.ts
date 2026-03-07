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
    id: 'overview',
    label: 'Overview',
    icon: '\uD83C\uDFE0',
    group: 'observe',
    description: 'Room health, keeper pressure, and top-line execution status',
  },
  {
    id: 'execution',
    label: 'Execution',
    icon: '\uD83D\uDEE0\uFE0F',
    group: 'observe',
    description: 'Intervention queue for stalled work, ownership gaps, and execution drift',
  },
  {
    id: 'agents',
    label: 'Agents',
    icon: '\uD83E\uDD16',
    group: 'observe',
    description: 'Live monitor for agent status, keeper pressure, and current execution focus',
  },
  {
    id: 'activity',
    label: 'Activity',
    icon: '\uD83D\uDCCA',
    group: 'observe',
    description: 'Unified live stream for messages, task changes, board events, and keeper events',
  },
  {
    id: 'board',
    label: 'Board',
    icon: '\uD83D\uDCAC',
    group: 'coordinate',
    description: 'Human and agent discussion feed with system noise filtered by default',
  },
  {
    id: 'council',
    label: 'Council',
    icon: '\uD83C\uDFDB\uFE0F',
    group: 'coordinate',
    description: 'Debates, quorum status, and decision flow',
  },
  {
    id: 'goals',
    label: 'Planning',
    icon: '\uD83C\uDFAF',
    group: 'coordinate',
    description: 'Goals and MDAL loops in one planning surface with freshness signals',
  },
  {
    id: 'tasks',
    label: 'Tasks',
    icon: '\uD83D\uDCCB',
    group: 'coordinate',
    description: 'Kanban-style task distribution',
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
