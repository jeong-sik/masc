import type { RouteState, TabId } from '../types'

type SurfaceId = TabId
export type DashboardSurfaceIcon =
  | 'overview'
  | 'monitoring'
  | 'command'
  | 'connectors'
  | 'workspace'
  | 'lab'
  | 'code'
  | 'logs'

type SurfaceSectionId =
  // monitoring
  | 'observatory'
  | 'journey'
  | 'agents'
  | 'cognition'
  | 'runtime'
  | 'goal-loop'
  | 'fleet-health'   // Phase 1: absorbs telemetry + fleet + tool-quality + monitoring governance
  // command
  | 'operations'     // Phase 1+6: absorbs intervene + governance + inspector (Phase 7: connectors split out)
  // connectors (Phase 7: top-level surface — sidecar-driven channel bridges)
  // Per-connector sub-tabs (discord/imessage/slack/telegram) were merged into
  // connector-status on 2026-04-30; selection happens inside the page via
  // ConnectorOverviewStrip rather than top-level navigation.
  | 'connector-status'      // all connectors with internal connector picker
  // workspace
  | 'board'
  | 'sub-boards'     // Phase 2: SubBoard named spaces within the board
  | 'planning'       // Phase 1: absorbs goals
  | 'repositories'   // Multi-repository cockpit and keeper access mapping
  | 'verification'   // CDAL follow-up (#7531): Mission detail verification table
  // lab
  | 'tools'
  | 'autoresearch'
  | 'harness'
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
}

export interface DashboardSectionNavItem {
  id: SurfaceSectionId
  label: string
  description: string
  params: Record<string, string>
  hidden?: boolean
}

export const DASHBOARD_SURFACES: DashboardNavGroup[] = [
  {
    id: 'cockpit',
    label: 'MASC Cockpit',
    icon: 'workspace',
    description: 'High-Fidelity MASC Cockpit',
    defaultTab: 'cockpit',
    tabs: ['cockpit'],
  },

  {
    id: 'overview',
    label: 'Overview',
    icon: 'overview',
    description: 'Fast signals and briefing rollup',
    defaultTab: 'overview',
    tabs: ['overview'],
  },
  {
    id: 'monitoring',
    label: 'Monitor',
    icon: 'monitoring',
    description: 'Fleet storylines, agents, runtime, and telemetry',
    defaultTab: 'monitoring',
    defaultParams: { section: 'journey' },
    tabs: ['monitoring'],
  },
  {
    id: 'command',
    label: 'Command',
    icon: 'command',
    description: 'Intervention, governance decisions, and approvals',
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
    label: 'Workspace',
    icon: 'workspace',
    description: 'Board, planning, repositories, and verification',
    defaultTab: 'workspace',
    defaultParams: { section: 'board' },
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
    label: 'Code',
    icon: 'code',
    description: 'Keeper collaboration IDE shell',
    defaultTab: 'code',
    defaultParams: { section: 'ide-shell' },
    tabs: ['code'],
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
}))

export const DASHBOARD_SECTION_ITEMS: Record<NonHomeTabId, DashboardSectionNavItem[]> = {
  cockpit: [],
  monitoring: [
    {
      id: 'journey',
      label: 'Journey Map',
      description: 'Task, run, contract, keeper, thinking, memory, turn, life, and cascade in one flow.',
      params: { section: 'journey' },
    },
    {
      id: 'observatory',
      label: 'Observatory',
      description: 'Live collaboration and investigative timelines remain drill-down surfaces.',
      params: { section: 'observatory' },
      // RFC-MASC-006 Phase 2a: kept as a hidden diagnostic surface, not yet promoted to main nav.
      // Reachable via legacy redirects (monitoring:activity, monitoring:live) and direct URL.
      // Remove hidden:true when Phase 2b drill-down is complete.
      hidden: true,
    },
    {
      id: 'agents',
      label: 'Agent Directory',
      description: 'Live runtime-backed roster and process state.',
      params: { section: 'agents' },
    },
    {
      id: 'cognition',
      label: 'Cognition',
      description: 'Keeper BDI, token load, memory, decisions, and autoresearch loops.',
      params: { section: 'cognition' },
    },
    {
      id: 'runtime',
      label: 'Cascade',
      description: 'Provider health, capacity, routing, cost, latency, and inspector views.',
      params: { section: 'runtime' },
    },
    {
      id: 'goal-loop',
      label: 'GOAL LOOP',
      description: 'Observe, Orient, Decide, Act, and Verify runtime status.',
      params: { section: 'goal-loop' },
    },
    {
      id: 'fleet-health',
      label: 'Fleet Telemetry',
      description: 'Event log, keeper comparison, tool quality, governance, and attribution signals.',
      params: { section: 'fleet-health' },
    },
  ],
  command: [
    {
      id: 'operations',
      label: 'Actions',
      description: 'Broadcasts, keeper messages, autonomy approvals, safety, and inspector controls.',
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
      id: 'board',
      label: 'Board',
      description: 'Human, agent, automation, and system posts.',
      params: { section: 'board' },
    },
    {
      id: 'sub-boards',
      label: 'Sub-Boards',
      description: 'Named spaces within the board with distinct access policies.',
      params: { section: 'sub-boards' },
    },
    {
      id: 'planning',
      label: 'Plans & Goals',
      description: 'Task kanban with the higher-level goal tree.',
      params: { section: 'planning' },
    },
    {
      id: 'repositories',
      label: 'Repositories',
      description: 'Registered repos, Git graph, branches, credentials, and keeper access scope.',
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
      id: 'autoresearch',
      label: 'Autoresearch',
      description: 'Autonomous experiment loop state and history.',
      params: { section: 'autoresearch' },
    },
    {
      id: 'harness',
      label: 'Safety Harness',
      description: 'Evaluation model, pre-compaction state, and generation handoff monitoring.',
      params: { section: 'harness' },
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
}

function validSectionIds(tab: NonHomeTabId): SurfaceSectionId[] {
  return DASHBOARD_SECTION_ITEMS[tab].map(item => item.id)
}

export function defaultParamsForTab(tabId: TabId): Record<string, string> {
  return DASHBOARD_SURFACES.find(surface => surface.id === tabId)?.defaultParams ?? {}
}

export function sectionItemsForTab(tabId: TabId): DashboardSectionNavItem[] {
  if (tabId === 'overview' || tabId === 'logs') return []
  return DASHBOARD_SECTION_ITEMS[tabId as NonHomeTabId]
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
  'monitoring:activity': { section: 'observatory' },
  'monitoring:live': { section: 'observatory', view: 'live' },

  // Dashboard consolidation Phase 1: monitoring surface
  'monitoring:telemetry':    { section: 'fleet-health', view: 'event-log' },
  'monitoring:fleet':        { section: 'fleet-health', view: 'comparison' },
  'monitoring:tool-quality': { section: 'fleet-health', view: 'tool-quality' },
  'monitoring:governance':   { section: 'fleet-health', view: 'governance' },
  'monitoring:attribution':   { section: 'fleet-health', view: 'attribution' },
  'monitoring:fsm-hub':      { section: 'agents', view: 'fsm' },
  'monitoring:metrics':      { section: 'runtime' },
  'monitoring:cascade-inspector': { section: 'runtime', view: 'inspector' },
  'monitoring:cost': { section: 'runtime', view: 'cost' },

  // Dashboard consolidation Phase 1+6: command surface
  'command:intervene':    { section: 'operations' },
  'command:governance':   { section: 'operations' },
  'command:connectors':   { section: 'operations', view: 'connectors' },
  'command:inspector':    { section: 'operations', view: 'inspector' },

  // Cognition UX cleanup: memory-subsystems merged into cognition > memory tab
  'monitoring:memory-subsystems': { section: 'cognition', params: { view: 'memory' } },

  // Dashboard consolidation Phase 1: workspace surface
  'workspace:goals': { section: 'planning' },

  // Dashboard consolidation Phase 7: per-connector sections collapsed into one picker.
  'connectors:connector-discord': { section: 'connector-status', params: { connector: 'discord' } },
  'connectors:connector-imessage': { section: 'connector-status', params: { connector: 'imessage' } },
  'connectors:connector-slack': { section: 'connector-status', params: { connector: 'slack' } },
  'connectors:connector-telegram': { section: 'connector-status', params: { connector: 'telegram' } },
}

export function normalizeRouteParams(tabId: TabId, params: Record<string, string>): Record<string, string> {
  const next = { ...params }
  const legacyObservatoryRanges = new Set(['1h', '6h', '24h', '7d'])

  if (tabId === 'overview' || tabId === 'logs') {
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

  delete next.surface
  delete next.operation
  delete next.run_id

  // Sections that use the `view` sub-param for internal navigation.
  // For all other sections, `view` is meaningless and must not leak in from prior navigation.
  const SECTIONS_WITH_VIEW = new Set([
    'fleet-health', 'runtime', 'agents', 'cognition', 'observatory',
  ])
  if (!next.section || !SECTIONS_WITH_VIEW.has(next.section)) {
    delete next.view
  }

  return next
}

export function currentSectionForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): DashboardSectionNavItem | null {
  if (routeState.tab === 'overview' || routeState.tab === 'logs') return null
  const normalized = normalizeRouteParams(routeState.tab, routeState.params)
  return sectionItemsForTab(routeState.tab).find(item => item.params.section === normalized.section) ?? null
}
