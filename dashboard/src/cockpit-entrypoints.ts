import type { TabId } from './types'

export type CockpitMode =
  | 'dashboard'
  | 'cockpit'
  | 'work'
  | 'comms'
  | 'observe'
  | 'cognition'
  | 'ide'
  | 'code'
  | 'split'
  | 'terminal'

export interface CockpitRouteTarget {
  tab: TabId
  params?: Record<string, string>
}

export interface CockpitEntrypoint {
  mode: CockpitMode
  aliases: string[]
  target: CockpitRouteTarget
  coverage: 'covered' | 'partial' | 'backend-blocked'
}

export const COCKPIT_MODE_TARGETS: Record<CockpitMode, CockpitRouteTarget> = {
  dashboard: { tab: 'overview' },
  cockpit: { tab: 'overview' },
  work: { tab: 'workspace', params: { section: 'planning' } },
  comms: { tab: 'workspace', params: { section: 'board' } },
  observe: { tab: 'monitoring', params: { section: 'runtime' } },
  cognition: { tab: 'monitoring', params: { section: 'cognition' } },
  ide: { tab: 'code', params: { section: 'ide-shell', view: 'source' } },
  code: { tab: 'code', params: { section: 'ide-shell', view: 'source' } },
  split: { tab: 'code', params: { section: 'ide-shell', view: 'split-diff' } },
  terminal: { tab: 'code', params: { section: 'ide-shell', view: 'source', terminal: 'open' } },
}

export const COCKPIT_ENTRYPOINTS: CockpitEntrypoint[] = [
  // Work Plane: Goal / Task / Accountability.
  { mode: 'work', aliases: ['goal-h', 'goal-horizon'], target: { tab: 'workspace', params: { section: 'planning', view: 'goal-tree' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['goal-t', 'goal-tree'], target: { tab: 'workspace', params: { section: 'planning', view: 'goal-tree' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['goal-d', 'goal-snapshot', 'goal-snapshot-diff'], target: { tab: 'workspace', params: { section: 'planning', view: 'goal-tree', focus: 'snapshot' } }, coverage: 'backend-blocked' },
  { mode: 'work', aliases: ['task-bl', 'task-backlog'], target: { tab: 'workspace', params: { section: 'planning', view: 'default' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['task-st', 'task-stale'], target: { tab: 'workspace', params: { section: 'planning', view: 'default', focus: 'stale' } }, coverage: 'partial' },
  { mode: 'work', aliases: ['task-w', 'task-wall'], target: { tab: 'workspace', params: { section: 'planning', view: 'default' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['acc-led', 'accountability-ledger'], target: { tab: 'workspace', params: { section: 'planning', focus: 'accountability-ledger' } }, coverage: 'partial' },
  { mode: 'work', aliases: ['acc-mtx', 'accountability-matrix'], target: { tab: 'workspace', params: { section: 'planning', focus: 'accountability-matrix' } }, coverage: 'partial' },

  // Comms Plane: board has production coverage; room/composer zones remain partial.
  { mode: 'comms', aliases: ['bd-feed', 'board-feed'], target: { tab: 'workspace', params: { section: 'board' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['bd-thr', 'board-thread'], target: { tab: 'workspace', params: { section: 'board', focus: 'thread' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['bd-tog', 'board-direct-automation'], target: { tab: 'workspace', params: { section: 'board', focus: 'automation' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['ms-rm', 'messages-room'], target: { tab: 'workspace', params: { section: 'board', focus: 'messages-room' } }, coverage: 'partial' },
  { mode: 'comms', aliases: ['ms-inb', 'messages-mention-inbox'], target: { tab: 'workspace', params: { section: 'board', focus: 'mention-inbox' } }, coverage: 'partial' },
  { mode: 'comms', aliases: ['ms-st', 'messages-state-block'], target: { tab: 'workspace', params: { section: 'board', focus: 'state-block' } }, coverage: 'partial' },
  { mode: 'comms', aliases: ['cm-bc', 'composer-broadcast'], target: { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'broadcast' } }, coverage: 'partial' },
  { mode: 'comms', aliases: ['cm-mn', 'composer-mention'], target: { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'mention' } }, coverage: 'partial' },
  { mode: 'comms', aliases: ['cm-st', 'composer-state'], target: { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'state' } }, coverage: 'partial' },

  // Observe Plane: split prototype tabs across the consolidated production surfaces.
  { mode: 'observe', aliases: ['cs-list', 'cascade-list'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cascade' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['cs-deep', 'cascade-deep-dive'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'inspector' } }, coverage: 'partial' },
  { mode: 'observe', aliases: ['cs-cmp', 'cascade-compare'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'providers' } }, coverage: 'partial' },
  { mode: 'observe', aliases: ['au-led', 'audit-ledger'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'audit' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['au-act', 'audit-by-actor'], target: { tab: 'monitoring', params: { section: 'fleet-health', view: 'attribution' } }, coverage: 'partial' },
  { mode: 'observe', aliases: ['au-sum', 'audit-summary'], target: { tab: 'monitoring', params: { section: 'fleet-health', view: 'governance' } }, coverage: 'partial' },
  { mode: 'observe', aliases: ['sa-dash', 'safe-auto-dashboard'], target: { tab: 'command', params: { section: 'operations', view: 'safety' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['sa-kpr', 'safe-auto-by-keeper'], target: { tab: 'command', params: { section: 'operations', view: 'safety', focus: 'keeper' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['sa-trd', 'safe-auto-trend'], target: { tab: 'command', params: { section: 'operations', view: 'safety', focus: 'trend' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['ct-agt', 'cost-per-agent'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cost' } }, coverage: 'partial' },
  { mode: 'observe', aliases: ['ct-mtx', 'cost-matrix'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cost', focus: 'matrix' } }, coverage: 'partial' },
  { mode: 'observe', aliases: ['ct-lat', 'cost-latency'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cost', focus: 'latency' } }, coverage: 'partial' },
  { mode: 'observe', aliases: ['hr-log', 'heuristic-log'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'heuristics', focus: 'log' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['hr-st', 'stress-board'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'stress' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['hr-mod', 'heuristic-by-module'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'heuristics', focus: 'module' } }, coverage: 'covered' },

  // Cognition Plane: production view tabs show available data and blocked backend gaps.
  { mode: 'cognition', aliases: ['ki-bdi', 'keeper-bdi'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'keeper', focus: 'bdi' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ki-acc', 'keeper-tool-access'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'keeper', focus: 'tool-access' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ki-stat', 'keeper-token-stats'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'token-stats' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['dc-str', 'decisions-stream'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'decisions' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['dc-mem', 'memory-entries'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'memory' } }, coverage: 'partial' },
  { mode: 'cognition', aliases: ['ep-card', 'episodes-cards'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'episodes' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ep-lrn', 'episodes-learnings'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'episodes' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ar-lst', 'ar-loops'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'autoresearch' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ar-fnd', 'ar-finding-card'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'autoresearch', focus: 'finding' } }, coverage: 'partial' },
  { mode: 'cognition', aliases: ['ar-flw', 'ar-flow'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'autoresearch', focus: 'flow' } }, coverage: 'partial' },

  // IDE Plane.
  { mode: 'ide', aliases: ['edit', 'source'], target: { tab: 'code', params: { section: 'ide-shell', view: 'source' } }, coverage: 'partial' },
  { mode: 'ide', aliases: ['review', 'pr-thread'], target: { tab: 'code', params: { section: 'ide-shell', view: 'unified', focus: 'review' } }, coverage: 'partial' },
  { mode: 'ide', aliases: ['merge', 'split', 'split-diff'], target: { tab: 'code', params: { section: 'ide-shell', view: 'split-diff' } }, coverage: 'partial' },
  { mode: 'ide', aliases: ['graph', 'git-graph'], target: { tab: 'workspace', params: { section: 'repositories', view: 'graph' } }, coverage: 'partial' },
  { mode: 'ide', aliases: ['search', 'find'], target: { tab: 'code', params: { section: 'ide-shell', view: 'source', focus: 'search' } }, coverage: 'partial' },
]

const ENTRYPOINT_TARGETS = new Map<string, CockpitRouteTarget>()

for (const entrypoint of COCKPIT_ENTRYPOINTS) {
  for (const alias of entrypoint.aliases) {
    ENTRYPOINT_TARGETS.set(`${entrypoint.mode}:${normalizeCockpitEntrypoint(alias)}`, entrypoint.target)
  }
}

export function normalizeCockpitMode(input: string | null | undefined): CockpitMode | null {
  const normalized = input?.trim().toLowerCase()
  if (!normalized) return null
  return Object.prototype.hasOwnProperty.call(COCKPIT_MODE_TARGETS, normalized)
    ? normalized as CockpitMode
    : null
}

export function normalizeCockpitEntrypoint(input: string): string {
  return input
    .trim()
    .toLowerCase()
    .replace(/[·/]+/g, ' ')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

export function cockpitEntryParam(params: Record<string, string>): string | null {
  return params.entry
    ?? params.panel
    ?? params.subtab
    ?? params.cockpit_tab
    ?? params.cockpitTab
    ?? params.tab
    ?? null
}

export function cockpitTargetForParams(params: Record<string, string>): CockpitRouteTarget | null {
  const mode = normalizeCockpitMode(params.mode ?? params.plane)
  if (!mode) return null
  const entry = cockpitEntryParam(params)
  if (entry) {
    const entryMode = mode === 'code' || mode === 'split' || mode === 'terminal' ? 'ide' : mode
    const entryTarget = ENTRYPOINT_TARGETS.get(`${entryMode}:${normalizeCockpitEntrypoint(entry)}`)
    if (entryTarget) return entryTarget
  }
  return COCKPIT_MODE_TARGETS[mode]
}
