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
  | 'registry'
  | 'board'
  | 'schedule'
  | 'fusion'
  | 'command'
  | 'connectors'
  | 'workspace'
  | 'lab'
  | 'code'
  | 'logs'
  | 'settings'
  | 'approvals'

type SurfaceSectionId =
  // monitoring
  | 'observatory'
  | 'agents'
  | 'internal-agents'
  | 'runtime'
  | 'fleet-health'   // Phase 1: absorbs telemetry + fleet + tool-quality + Gate monitoring
  | 'transport-health' // Hidden support route for transport diagnostics; linked from Runtime.
  | 'journey' // Hidden execution-flow drill-down.
  | 'lane-addons'
  | 'lane-inventory'
  | 'lanes' // Lane · Queue — 실행 타임라인 + 대기 큐 (keeper-v2 lanes.jsx).
  | 'skills' // SKILL.md catalog keepers load at turn start, with usage (RFC skills-as-tools §2.6).
  // command
  | 'operations'     // Phase 1+6: absorbs intervene + Gate + inspector (Phase 7: connectors split out)
  // connectors (top-level surface for server-owned channel gateways)
  // Per-connector sub-tabs (discord/imessage/slack/telegram) were merged into
  // connector-status on 2026-04-30; selection happens inside the page via
  // ConnectorOverviewStrip rather than top-level navigation.
  | 'connector-status'      // all connectors with internal connector picker
  // workspace
  | 'work'           // Goal/job breakdown surface
  | 'board'
  | 'sub-boards'     // Phase 2: SubBoard named spaces within the board
  | 'planning'       // Phase 1: absorbs goals
  | 'repositories'   // Multi-repository cockpit and keeper access mapping
  | 'verification'   // Contract follow-up (#7531): Mission detail verification table
  | 'artifacts'
  // lab
  | 'tools'
  | 'harness'
  | 'keeper-memory-health'
  // code (Stage 5 IDE plane — shell only in PR-1, 4-pane content in PR-2+)
  | 'ide-shell'

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

// Order mirrors the keeper-v2 prototype rail (shell.jsx, #29046): 개요 ·
// Keepers · 레지스트리 · Monitor · 작업 · Gate · 예약 · 보드 · Fusion · 로그 ·
// IDE · 커넥터 · 명령 · Lab · 설정. The prototype's rail is the design SSOT the
// parity probes measure; the older 2026-07 standalone export predates its
// 명령/Lab group. Settings stays pinned in the rail footer, so it renders
// outside the main list even though it closes this set.
export const V2_PRIMARY_SURFACE_IDS: ReadonlyArray<SurfaceId> = [
  'overview',
  'keepers',
  'registry',
  'monitoring',
  'workspace',
  'approvals',
  'schedule',
  'board',
  'fusion',
  'logs',
  'code',
  'connectors',
  'command',
  'lab',
  'settings',
]

export function isPrimaryDashboardSurface(tabId: TabId): boolean {
  return V2_PRIMARY_SURFACE_IDS.includes(tabId)
}

const SECTIONLESS_SURFACE_IDS: ReadonlySet<TabId> = new Set([
  'overview',
  'logs',
  'settings',
  'keepers',
  'registry',
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
    description: 'Keeper operations, tools, runtime, and evidence',
    defaultTab: 'monitoring',
    defaultParams: { section: 'agents' },
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
    id: 'registry',
    label: 'Registry',
    icon: 'registry',
    description: 'Keeper instances, instructions, and runtime bindings',
    defaultTab: 'registry',
    tabs: ['registry'],
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
    id: 'command',
    label: 'Command',
    icon: 'command',
    description: 'Interventions, keeper messages, and questions',
    defaultTab: 'command',
    defaultParams: { section: 'operations' },
    tabs: ['command'],
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
    description: 'Work goals, planning, repositories, and verification',
    defaultTab: 'workspace',
    defaultParams: { section: 'work' },
    tabs: ['workspace'],
  },
  {
    id: 'lab',
    label: 'Lab',
    icon: 'lab',
    description: 'Tool diagnostics and experiment control',
    defaultTab: 'lab',
    defaultParams: { section: 'tools' },
    tabs: ['lab'],
  },
  {
    id: 'code',
    label: 'IDE',
    icon: 'code',
    description: 'Keeper collaboration IDE shell',
    defaultTab: 'code',
    defaultParams: { section: 'ide-shell' },
    tabs: ['code'],
  },
  {
    id: 'settings',
    label: 'Settings',
    icon: 'settings',
    description: 'Operator console for keeper-v2 configuration',
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

export const VISIBLE_DASHBOARD_NAV_ITEMS: DashboardNavItem[] =
  DASHBOARD_NAV_ITEMS.filter(item => item.hidden !== true)

export const PRIMARY_DASHBOARD_SURFACES: DashboardNavGroup[] =
  V2_PRIMARY_SURFACE_IDS.flatMap(id => {
    const surface = DASHBOARD_SURFACES.find(item => item.id === id && item.hidden !== true)
    return surface ? [surface] : []
  })

export const PRIMARY_DASHBOARD_NAV_ITEMS: DashboardNavItem[] =
  V2_PRIMARY_SURFACE_IDS.flatMap(id => {
    const item = DASHBOARD_NAV_ITEMS.find(navItem => navItem.id === id && navItem.hidden !== true)
    return item ? [item] : []
  })

export const DASHBOARD_SECTION_ITEMS: Record<NonHomeTabId, DashboardSectionNavItem[]> = {
  // Sectionless surface (single tab, no sub-sections) but still a NonHomeTabId
  // key — the Record is exhaustive over the union, so the empty entry is required.
  approvals: [],
  fusion: [],
  registry: [],
  monitoring: [
    {
      id: 'agents',
      label: 'Keeper Fleet',
      description: 'Live and configured keeper roster.',
      params: { section: 'agents' },
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
      id: 'runtime',
      label: 'Runtime',
      description: 'Runtime lane health.',
      params: { section: 'runtime' },
    },
    {
      id: 'observatory',
      label: 'Observatory',
      description: 'Activity and runtime evidence.',
      params: { section: 'observatory' },
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
    {
      id: 'journey',
      label: 'Journey Map',
      description: 'Execution-flow drill-down.',
      params: { section: 'journey' },
      hidden: true,
    },
  ],
  keepers: [],
  board: [],
  schedule: [],
  command: [
    {
      id: 'operations',
      label: 'Actions',
      description: 'Broadcasts, keeper messages, questions, and server configuration.',
      params: { section: 'operations' },
    },
  ],
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
      id: 'planning',
      label: 'Plans & Goals',
      description: 'Goal tree and task kanban.',
      params: { section: 'planning' },
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
  lab: [
    {
      id: 'tools',
      label: 'Tools',
      description: 'Registered MCP tools across servers.',
      params: { section: 'tools' },
    },
    {
      id: 'harness',
      label: 'Safety Harness',
      description: 'Evaluation model, pre-handoff state, and generation handoff monitoring.',
      params: { section: 'harness' },
    },
    {
      id: 'keeper-memory-health',
      label: '키퍼 메모리 상태',
      description: 'Per-keeper ordinary/source snapshots, Vision ingest failures, deltas, and cadence.',
      params: { section: 'keeper-memory-health' },
    },
  ],
  code: [
    {
      id: 'ide-shell',
      label: 'Code IDE',
      description: 'Keeper collaboration code-review IDE shell.',
      params: { section: 'ide-shell' },
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
  // Target identity only belongs to these receiver surfaces. Ordinary
  // navigation must not carry an old Lane selection into an unrelated screen.
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

  if (!(tabId === 'code' && next.section === 'ide-shell')) {
    delete next.surface
  }

  if (tabId === 'connectors' && !isKnownConnectorId(next.connector)) {
    delete next.connector
  }
  delete next.operation
  delete next.run_id

  // Sections that use the `view` sub-param for internal navigation.
  // For all other sections, `view` is meaningless and must not leak in from prior navigation.
  const SECTIONS_WITH_VIEW = new Set([
    'fleet-health', 'runtime', 'agents', 'observatory',
    'repositories', 'operations', 'ide-shell', 'planning',
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
