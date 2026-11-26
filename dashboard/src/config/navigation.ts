import type { RouteState, TabId } from '../types'
import { isKnownConnectorId } from './connector-ids'

type SurfaceId = TabId
export const SETTINGS_ROUTE_SECTION_IDS = [
  'account',
  'runtime',
  'routing',
  'runtimes',
  'paths',
  'mcp',
  'repositories',
  'notify',
  'prompts',
  'fusion',
  'logs',
  'display',
] as const
export type SettingsRouteSectionId = typeof SETTINGS_ROUTE_SECTION_IDS[number]

const SETTINGS_ROUTE_SECTION_SET = new Set<string>(SETTINGS_ROUTE_SECTION_IDS)

function isSettingsRouteSection(value: string | undefined): value is SettingsRouteSectionId {
  return !!value && SETTINGS_ROUTE_SECTION_SET.has(value)
}

export type DashboardSurfaceIcon =
  | 'overview'
  | 'monitoring'
  | 'keepers'
  | 'board'
  | 'schedule'
  | 'fusion'
  | 'connectors'
  | 'workspace'
  | 'logs'
  | 'settings'
  | 'approvals'

type SurfaceSectionId =
  | 'internal-agents'
  | 'runtime'
  | 'fleet-health'
  | 'transport-health'
  | 'lane-addons'
  | 'lane-inventory'
  | 'lanes'
  | 'skills'
  | 'connector-status'
  | 'work'
  | 'board'
  | 'sub-boards'
  | 'repositories'
  | 'verification'
  | 'artifacts'

export type NonHomeTabId = Exclude<TabId, 'overview' | 'logs'>

interface DashboardNavGroup {
  id: SurfaceId
  label: string
  icon: DashboardSurfaceIcon
  description: string
  defaultTab: TabId
  defaultParams?: Record<string, string>
  tabs: TabId[]
  hidden?: boolean
}

interface DashboardNavItem {
  id: TabId
  label: string
  icon: DashboardSurfaceIcon
  description: string
  defaultParams?: Record<string, string>
  hidden?: boolean
}

export interface DashboardSectionNavItem {
  id: SurfaceSectionId
  label: string
  description: string
  params: Record<string, string>
  hidden?: boolean
}

const SECTIONLESS_SURFACE_IDS: ReadonlySet<TabId> = new Set([
  'overview',
  'logs',
  'settings',
  'keepers',
  'board',
  'schedule',
  'approvals',
  'fusion',
])

export function isSectionlessSurface(tabId: TabId): boolean {
  return SECTIONLESS_SURFACE_IDS.has(tabId)
}

export const DASHBOARD_SURFACES: DashboardNavGroup[] = [
  {
    id: 'overview',
    label: 'Overview',
    icon: 'overview',
    description: 'Signals and briefing rollup',
    defaultTab: 'overview',
    tabs: ['overview'],
  },
  {
    id: 'monitoring',
    label: 'Monitor',
    icon: 'monitoring',
    description: 'Tools, runtime, lanes, and transport diagnostics',
    defaultTab: 'monitoring',
    defaultParams: { section: 'runtime' },
    tabs: ['monitoring'],
  },
  {
    id: 'keepers',
    label: 'Keepers',
    icon: 'keepers',
    description: 'Dedicated keeper roster, conversation, and context workspace',
    defaultTab: 'keepers',
    tabs: ['keepers'],
  },
  {
    id: 'board',
    label: 'Board',
    icon: 'board',
    description: 'Human, agent, automation, and system posts',
    defaultTab: 'board',
    tabs: ['board'],
  },
  {
    id: 'schedule',
    label: 'Schedule',
    icon: 'schedule',
    description: 'Scheduled keeper automation and wake signals',
    defaultTab: 'schedule',
    tabs: ['schedule'],
  },
  {
    id: 'approvals',
    label: 'Gate',
    icon: 'approvals',
    description: 'Nonblocking Keeper HITL queue and exact Always rules',
    defaultTab: 'approvals',
    tabs: ['approvals'],
  },
  {
    id: 'fusion',
    label: 'Fusion',
    icon: 'fusion',
    description: 'Panel and judge deliberations emitted by masc_fusion',
    defaultTab: 'fusion',
    tabs: ['fusion'],
  },
  {
    id: 'connectors',
    label: 'Connectors',
    icon: 'connectors',
    description: 'Channel bridges and keeper bindings',
    defaultTab: 'connectors',
    defaultParams: { section: 'connector-status' },
    tabs: ['connectors'],
  },
  {
    id: 'workspace',
    label: 'Work',
    icon: 'workspace',
    description: 'Work goals, repositories, artifacts, and verification',
    defaultTab: 'workspace',
    defaultParams: { section: 'work' },
    tabs: ['workspace'],
  },
  {
    id: 'settings',
    label: 'Settings',
    icon: 'settings',
    description: 'Operator console for MASC configuration',
    defaultTab: 'settings',
    tabs: ['settings'],
  },
  {
    id: 'logs',
    label: 'Logs',
    icon: 'logs',
    description: 'System execution logs',
    defaultTab: 'logs',
    tabs: ['logs'],
  },
]

export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = DASHBOARD_SURFACES.map(surface => ({
  id: surface.id,
  label: surface.label,
  icon: surface.icon,
  description: surface.description,
  defaultParams: surface.defaultParams,
  hidden: surface.hidden,
}))

export const DASHBOARD_SECTION_ITEMS: Record<NonHomeTabId, DashboardSectionNavItem[]> = {
  approvals: [],
  fusion: [],
  monitoring: [
    {
      id: 'runtime',
      label: 'Runtime',
      description: 'Runtime lane health.',
      params: { section: 'runtime' },
    },
    {
      id: 'internal-agents',
      label: 'Internal Agents',
      description: 'Nondeterministic runs and tool evidence.',
      params: { section: 'internal-agents' },
    },
    {
      id: 'fleet-health',
      label: 'Tool Monitor',
      description: 'Tool quality and Gate signals.',
      params: { section: 'fleet-health' },
    },
    {
      id: 'skills',
      label: 'Skills',
      description: 'SKILL.md catalog and usage.',
      params: { section: 'skills' },
    },
    {
      id: 'lane-inventory',
      label: 'All Lanes',
      description: 'Built-in Lanes, package declarations and manual workers.',
      params: { section: 'lane-inventory' },
    },
    {
      id: 'lane-addons',
      label: 'Lane Add-ons',
      description: 'Optional cross-lane observations and relationships.',
      params: { section: 'lane-addons' },
    },
    {
      id: 'lanes',
      label: 'Lane · Queue',
      description: 'Keeper 실행 타임라인과 대기 큐.',
      params: { section: 'lanes' },
    },
    {
      id: 'transport-health',
      label: 'Transport Health',
      description: 'Transport diagnostics.',
      params: { section: 'transport-health' },
      hidden: true,
    },
  ],
  keepers: [],
  board: [],
  schedule: [],
  connectors: [
    {
      id: 'connector-status',
      label: 'All',
      description: 'Discord, iMessage, Slack, and Telegram channels in one surface.',
      params: { section: 'connector-status' },
    },
  ],
  workspace: [
    {
      id: 'work',
      label: 'Work',
      description: 'Goal/job breakdown and keeper assignment board.',
      params: { section: 'work' },
    },
    {
      id: 'artifacts',
      label: 'Artifacts',
      description: 'Reports and documents published by Keepers.',
      params: { section: 'artifacts' },
    },
    {
      id: 'board',
      label: 'Board',
      description: 'Human, agent, automation, and system posts.',
      params: { section: 'board' },
      hidden: true,
    },
    {
      id: 'sub-boards',
      label: 'Sub-Boards',
      description: 'Named spaces within the board with distinct access policies.',
      params: { section: 'sub-boards' },
      hidden: true,
    },
    {
      id: 'repositories',
      label: 'Repositories',
      description: 'Registered repos, branches, and keeper access scope.',
      params: { section: 'repositories' },
    },
    {
      id: 'verification',
      label: 'Verification',
      description: 'Cross-agent verification requests, completion contracts, and evidence.',
      params: { section: 'verification' },
    },
  ],
  settings: [],
}

function validSectionIds(tab: NonHomeTabId): SurfaceSectionId[] {
  return DASHBOARD_SECTION_ITEMS[tab].map(item => item.id)
}

export function defaultParamsForTab(tabId: TabId): Record<string, string> {
  return DASHBOARD_SURFACES.find(surface => surface.id === tabId)?.defaultParams ?? {}
}

export function sectionItemsForTab(tabId: TabId): DashboardSectionNavItem[] {
  if (isSectionlessSurface(tabId)) return []
  return DASHBOARD_SECTION_ITEMS[tabId as NonHomeTabId]
}

export function visibleSectionItemsForTab(tabId: TabId): DashboardSectionNavItem[] {
  return sectionItemsForTab(tabId).filter(item => item.hidden !== true)
}

export function normalizeRouteParams(tabId: TabId, params: Record<string, string>): Record<string, string> {
  const next = { ...params }
  if (tabId !== 'approvals') delete next.approval
  if (tabId !== 'monitoring' || !['runtime', 'lane-addons', 'internal-agents'].includes(next.section ?? '')) delete next.lane_target

  if (tabId === 'settings') {
    if (!isSettingsRouteSection(next.section)) {
      delete next.section
    }
    delete next.surface
    return next
  }

  if (isSectionlessSurface(tabId)) {
    delete next.section
    delete next.surface
    return next
  }

  const typedTabId = tabId as NonHomeTabId

  if (!validSectionIds(typedTabId).includes(next.section as SurfaceSectionId)) {
    next.section = defaultParamsForTab(tabId).section ?? ''
  }

  delete next.surface

  if (tabId === 'connectors' && !isKnownConnectorId(next.connector)) {
    delete next.connector
  }
  delete next.operation
  delete next.run_id

  const SECTIONS_WITH_VIEW = new Set([
    'fleet-health', 'runtime', 'repositories',
  ])
  if (!next.section || !SECTIONS_WITH_VIEW.has(next.section)) {
    delete next.view
  }

  return next
}

export function currentSectionForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): DashboardSectionNavItem | null {
  if (isSectionlessSurface(routeState.tab)) return null
  const normalized = normalizeRouteParams(routeState.tab, routeState.params)
  return sectionItemsForTab(routeState.tab).find(item => item.params.section === normalized.section) ?? null
}
