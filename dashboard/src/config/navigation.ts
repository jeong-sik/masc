import type { RouteState, TabId } from '../types'

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

const CONNECTOR_ROUTE_IDS = ['discord', 'imessage', 'slack', 'telegram'] as const
type ConnectorRouteId = typeof CONNECTOR_ROUTE_IDS[number]
const CONNECTOR_ROUTE_ID_SET = new Set<string>(CONNECTOR_ROUTE_IDS)

function isConnectorRouteId(value: string | undefined): value is ConnectorRouteId {
  return !!value && CONNECTOR_ROUTE_ID_SET.has(value)
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
  | 'runtime'
  | 'fleet-health'   // Phase 1: absorbs telemetry + fleet + tool-quality + Gate monitoring
  | 'transport-health' // Hidden support route for transport diagnostics; linked from Runtime.
  | 'feature-health' // Hidden support route for feature flag diagnostics; linked from Runtime.
  | 'journey' // Hidden execution-flow drill-down.
  | 'cognition' // Hidden keeper cognition drill-down.
  // command
  | 'operations'     // Phase 1+6: absorbs intervene + Gate + inspector (Phase 7: connectors split out)
  // connectors (Phase 7: top-level surface — sidecar-driven channel bridges)
  // Per-connector sub-tabs (discord/imessage/slack/telegram) were merged into
  // connector-status on 2026-04-30; selection happens inside the page via
  // ConnectorOverviewStrip rather than top-level navigation.
  | 'connector-status'      // all connectors with internal connector picker
  // workspace
  | 'work'           // Goal/job breakdown surface
  | 'board'
  | 'sub-boards'     // Phase 2: SubBoard named spaces within the board
  | 'moderation'     // Board moderation queue and actions
  | 'planning'       // Phase 1: absorbs goals
  | 'repositories'   // Multi-repository cockpit and keeper access mapping
  | 'verification'   // Contract follow-up (#7531): Mission detail verification table
  // lab
  | 'tools'
  | 'harness'
  | 'performance'
  | 'memory-subsystems'
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

// Order mirrors the 2026-07 keeper-v2 standalone export's rail: 개요 · Keepers ·
// Monitor · 작업 · 승인 · 예약 · 보드 · Fusion · 로그 · IDE · 커넥터 · 설정.
// That export restored Monitor to the primary rail and moved Logs before IDE,
// so the earlier #21525 operator-restored-Logs deviation is now the design
// itself. Settings stays pinned in the rail footer, so it renders outside the
// main list even though it closes this set.
const V2_PRIMARY_SURFACE_IDS: ReadonlyArray<SurfaceId> = [
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
    id: 'cockpit',
    label: 'MASC Cockpit',
    icon: 'workspace',
    description: 'MASC Cockpit',
    defaultTab: 'cockpit',
    tabs: ['cockpit'],
    hidden: true,
  },

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
    description: 'Persona forms, keeper instances, and runtime bindings',
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
    description: 'Intervention, Gate decisions, and HITL',
    defaultTab: 'command',
    defaultParams: { section: 'operations' },
    tabs: ['command'],
  },
  {
    id: 'connectors',
    label: 'Connectors',
    icon: 'connectors',
    description: 'Channel sidecars and keeper bindings',
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
  cockpit: [],
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
      id: 'transport-health',
      label: 'Transport Health',
      description: 'Transport diagnostics.',
      params: { section: 'transport-health' },
      hidden: true,
    },
    {
      id: 'feature-health',
      label: 'Feature Flags',
      description: 'Feature diagnostics.',
      params: { section: 'feature-health' },
      hidden: true,
    },
    {
      id: 'journey',
      label: 'Journey Map',
      description: 'Execution-flow drill-down.',
      params: { section: 'journey' },
      hidden: true,
    },
    {
      id: 'cognition',
      label: 'Keeper Cognition',
      description: 'Keeper cognition and memory drill-down.',
      params: { section: 'cognition' },
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
      description: 'Broadcasts, keeper messages, Gate/HITL, and inspector controls.',
      params: { section: 'operations' },
    },
  ],
  connectors: [
    {
      id: 'connector-status',
      label: 'All',
      description: 'Discord, iMessage, Slack, and Telegram sidecars in one surface.',
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
      id: 'moderation',
      label: 'Moderation',
      description: 'Flagged board posts and moderation actions.',
      params: { section: 'moderation' },
      hidden: true,
    },
    {
      id: 'planning',
      label: 'Plans & Goals',
      description: 'Goal loop, goal tree, and task kanban.',
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
      description: 'Evaluation model, pre-compaction state, and generation handoff monitoring.',
      params: { section: 'harness' },
    },
    {
      id: 'performance',
      label: 'Performance',
      description: 'FPS meter, VirtualList, content-visibility, native dialog, and observer probes.',
      params: { section: 'performance' },
    },
    {
      id: 'memory-subsystems',
      label: 'Memory OS',
      description: 'Live episodes, user model projection, Hebbian synapses, and gated memory entries.',
      params: { section: 'memory-subsystems' },
    },
    {
      id: 'keeper-memory-health',
      label: '키퍼 메모리 상태',
      description: 'Per-keeper fact-store size, GC statistics, and cadence counter.',
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
  // Total: an unknown/unmapped tab has no sections. Guards against a route
  // whose tab is not a section-bearing surface (e.g. partial routes in tests
  // or a not-yet-registered surface) instead of crashing on undefined.map.
  return (DASHBOARD_SECTION_ITEMS[tab] ?? []).map(item => item.id)
}

export function defaultParamsForTab(tabId: TabId): Record<string, string> {
  return DASHBOARD_SURFACES.find(surface => surface.id === tabId)?.defaultParams ?? {}
}

export function sectionItemsForTab(tabId: TabId): DashboardSectionNavItem[] {
  if (isSectionlessSurface(tabId)) return []
  return DASHBOARD_SECTION_ITEMS[tabId as NonHomeTabId] ?? []
}

export function visibleSectionItemsForTab(tabId: TabId): DashboardSectionNavItem[] {
  return sectionItemsForTab(tabId).filter(item => item.hidden !== true)
}

/**
 * Redirect table for legacy section IDs.
 *
 * Key: (tab, old section) → value: { section, view? }
 *
 * `view` sets the view query param when absent, for canonicalization into
 * fleet-health sub-views.
 *
 * Contract:
 *   - Redirects are applied BEFORE section validation.
 *   - Caller-supplied query params (session_id, operation_id, worker_run_id,
 *     tool, target_id, keeper, agent, ns, range, etc.) are preserved.
 *   - This function MUST remain pure. Side effects (modal open, analytics)
 *     must live in router/app effects, not here.
 *   - Cross-surface redirects are not supported (normalizeRouteParams returns
 *     params for the same tab). Cross-surface routing lives in the router.
 */
interface SectionRedirect {
  section: string
  view?: string
  params?: Record<string, string>
}

type TabSectionKey = `${TabId}:${string}`

export const SECTION_REDIRECTS: Record<TabSectionKey, SectionRedirect> = {
  // RFC-MASC-006 Phase 0: sessions stub removed
  'monitoring:sessions': { section: 'agents' },

  // Dashboard consolidation Phase 1: monitoring surface
  'monitoring:telemetry':    { section: 'fleet-health', view: 'event-log' },
  'monitoring:fleet':        { section: 'fleet-health', view: 'comparison' },
  'monitoring:tool-quality': { section: 'fleet-health', view: 'tool-quality' },
  'monitoring:gate':          { section: 'fleet-health', view: 'gate' },
  'monitoring:attribution':   { section: 'fleet-health', view: 'attribution' },
  'monitoring:fsm-hub':      { section: 'agents', view: 'fsm' },
  'monitoring:metrics':      { section: 'runtime' },
  'monitoring:cost': { section: 'runtime', view: 'cost' },

  // Dashboard consolidation Phase 1+6: command surface
  'command:intervene':    { section: 'operations' },
  'command:gate':         { section: 'operations', view: 'gate' },
  'command:inspector':    { section: 'operations', view: 'inspector' },

  // Dashboard consolidation Phase 1: workspace surface
  'workspace:goals': { section: 'planning' },

  // Dashboard consolidation Phase 7: per-connector sections collapsed into one picker.
  'connectors:connector-discord': { section: 'connector-status', params: { connector: 'discord' } },
  'connectors:connector-imessage': { section: 'connector-status', params: { connector: 'imessage' } },
  'connectors:connector-slack': { section: 'connector-status', params: { connector: 'slack' } },
  'connectors:connector-telegram': { section: 'connector-status', params: { connector: 'telegram' } },

  // Keeper v2 parity: the old Lab Memory Explore route used hard-coded sample
  // graph data. Collapse legacy links into the backed Memory OS projection.
  'lab:memory-explore': { section: 'memory-subsystems' },

  // Keeper v2 parity: Design Canvas was a static preview over prototype
  // fixture data. Collapse legacy links into the backed Lab tools inventory.
  'lab:design-canvas': { section: 'tools' },
}

export function normalizeRouteParams(tabId: TabId, params: Record<string, string>): Record<string, string> {
  const next = { ...params }
  const legacyObservatoryRanges = new Set(['1h', '6h', '24h', '7d'])

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

  // Apply redirect table (pure transform: no side effects).
  const inputSection = next.section
  if (inputSection) {
    if (tabId === 'monitoring' && inputSection === 'activity') {
      const legacyRange = next.ag_range
      if (legacyRange && !next.range && legacyObservatoryRanges.has(legacyRange)) {
        next.range = legacyRange
      }
      delete next.ag_range
    }

    const redirect = SECTION_REDIRECTS[`${tabId}:${inputSection}` as TabSectionKey]
    if (redirect) {
      for (const [key, value] of Object.entries(redirect.params ?? {})) {
        if (!next[key]) next[key] = value
      }
      if (redirect.view && !next.view) next.view = redirect.view
      next.section = redirect.section
      // Cross-surface redirect handled by caller (router) — see contract doc.
    }
  }

  const typedTabId = tabId as NonHomeTabId

  if (!validSectionIds(typedTabId).includes(next.section as SurfaceSectionId)) {
    next.section = defaultParamsForTab(tabId).section ?? ''
  }

  if (!(tabId === 'code' && next.section === 'ide-shell')) {
    delete next.surface
  }

  if (tabId === 'connectors' && !isConnectorRouteId(next.connector)) {
    delete next.connector
  }
  delete next.operation
  delete next.run_id

  // Sections that use the `view` sub-param for internal navigation.
  // For all other sections, `view` is meaningless and must not leak in from prior navigation.
  // `repositories` / `operations` / `ide-shell` are redirect targets in
  // `CROSS_SURFACE_SECTION_REDIRECTS` (router.ts) and `SECTION_REDIRECTS`
  // (this file, line 332+) that carry `view` as part of the canonical destination
  // (e.g. `monitoring:git-graph → workspace:repositories`,
  // cockpit IDE `?mode=Split → code:ide-shell?view=split-diff`).
  // `planning` does not gain `view` via redirect (`workspace:goals → planning`
  // drops view); instead, direct `replaceRoute` callers pass `view: 'default'`
  // as the canonical planning entry point (see router.test.ts replaceRoute case).
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
