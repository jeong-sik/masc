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
  | 'explode'

export type CognitiveMode = 'cockpit' | 'code' | 'split' | 'explode'

export interface CockpitRouteTarget {
  tab: TabId
  params?: Record<string, string>
}

export interface CockpitEntrypoint {
  mode: CockpitMode
  aliases: string[]
  target: CockpitRouteTarget
  coverage: 'covered' | 'backend-blocked'
}

export interface CognitiveModeState {
  mode: CognitiveMode
  label: string
  load: 'situational' | 'focused' | 'comparative' | 'exploratory'
  layout: 'all-panels' | 'editor-first' | 'side-by-side' | 'graph-map'
  target: CockpitRouteTarget
  cockpitModes: readonly CockpitMode[]
}

export const COGNITIVE_MODE_ORDER: CognitiveMode[] = ['cockpit', 'code', 'split', 'explode']

export const COGNITIVE_MODE_TARGETS: Record<CognitiveMode, CockpitRouteTarget> = {
  cockpit: { tab: 'overview' },
  code: { tab: 'code', params: { section: 'ide-shell', view: 'source' } },
  split: { tab: 'code', params: { section: 'ide-shell', view: 'split-diff' } },
  explode: { tab: 'workspace', params: { section: 'repositories', view: 'graph' } },
}

export const COGNITIVE_MODE_STATES: Record<CognitiveMode, CognitiveModeState> = {
  cockpit: {
    mode: 'cockpit',
    label: 'Cockpit',
    load: 'situational',
    layout: 'all-panels',
    target: COGNITIVE_MODE_TARGETS.cockpit,
    cockpitModes: ['dashboard', 'cockpit', 'work', 'comms', 'observe', 'cognition'],
  },
  code: {
    mode: 'code',
    label: 'Code',
    load: 'focused',
    layout: 'editor-first',
    target: COGNITIVE_MODE_TARGETS.code,
    cockpitModes: ['ide', 'code', 'terminal'],
  },
  split: {
    mode: 'split',
    label: 'Split',
    load: 'comparative',
    layout: 'side-by-side',
    target: COGNITIVE_MODE_TARGETS.split,
    cockpitModes: ['split'],
  },
  explode: {
    mode: 'explode',
    label: 'Explode',
    load: 'exploratory',
    layout: 'graph-map',
    target: COGNITIVE_MODE_TARGETS.explode,
    cockpitModes: ['explode'],
  },
}

const COCKPIT_MODE_TO_COGNITIVE_MODE = new Map<CockpitMode, CognitiveMode>(
  COGNITIVE_MODE_ORDER.flatMap(mode =>
    COGNITIVE_MODE_STATES[mode].cockpitModes.map(cockpitMode => [cockpitMode, mode] as const),
  ),
)

export const COCKPIT_MODE_TARGETS: Record<CockpitMode, CockpitRouteTarget> = {
  dashboard: COGNITIVE_MODE_TARGETS.cockpit,
  cockpit: COGNITIVE_MODE_TARGETS.cockpit,
  work: { tab: 'workspace', params: { section: 'planning' } },
  comms: { tab: 'workspace', params: { section: 'board' } },
  observe: { tab: 'monitoring', params: { section: 'runtime' } },
  cognition: { tab: 'monitoring', params: { section: 'cognition' } },
  ide: COGNITIVE_MODE_TARGETS.code,
  code: COGNITIVE_MODE_TARGETS.code,
  split: COGNITIVE_MODE_TARGETS.split,
  terminal: { tab: 'code', params: { section: 'ide-shell', view: 'source', terminal: 'open' } },
  explode: COGNITIVE_MODE_TARGETS.explode,
}

export const COCKPIT_ENTRYPOINTS: CockpitEntrypoint[] = [
  // Work Plane: Goal / Task / Accountability.
  { mode: 'work', aliases: ['goal-h', 'goal-horizon'], target: { tab: 'workspace', params: { section: 'planning', view: 'goal-tree' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['goal-t', 'goal-tree'], target: { tab: 'workspace', params: { section: 'planning', view: 'goal-tree' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['goal-d', 'goal-snapshot', 'goal-snapshot-diff'], target: { tab: 'workspace', params: { section: 'planning', view: 'goal-tree', focus: 'snapshot' } }, coverage: 'backend-blocked' },
  { mode: 'work', aliases: ['task-bl', 'task-backlog'], target: { tab: 'workspace', params: { section: 'planning', view: 'default' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['task-st', 'task-stale'], target: { tab: 'workspace', params: { section: 'planning', view: 'default', focus: 'stale' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['task-w', 'task-wall'], target: { tab: 'workspace', params: { section: 'planning', view: 'default' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['acc-led', 'accountability-ledger'], target: { tab: 'workspace', params: { section: 'planning', focus: 'accountability-ledger' } }, coverage: 'covered' },
  { mode: 'work', aliases: ['acc-mtx', 'accountability-matrix'], target: { tab: 'workspace', params: { section: 'planning', focus: 'accountability-matrix' } }, coverage: 'covered' },

  // Comms Plane: board, message focus, and composer surfaces have production coverage.
  { mode: 'comms', aliases: ['bd-feed', 'board-feed'], target: { tab: 'workspace', params: { section: 'board' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['bd-thr', 'board-thread'], target: { tab: 'workspace', params: { section: 'board', focus: 'thread' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['bd-tog', 'board-direct-automation'], target: { tab: 'workspace', params: { section: 'board', focus: 'automation' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['ms-rm', 'messages-room'], target: { tab: 'workspace', params: { section: 'board', focus: 'messages-room' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['ms-inb', 'messages-mention-inbox'], target: { tab: 'workspace', params: { section: 'board', focus: 'mention-inbox' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['ms-st', 'messages-state-block'], target: { tab: 'workspace', params: { section: 'board', focus: 'state-block' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['cm-bc', 'composer-broadcast'], target: { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'broadcast' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['cm-mn', 'composer-mention'], target: { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'mention' } }, coverage: 'covered' },
  { mode: 'comms', aliases: ['cm-st', 'composer-state'], target: { tab: 'command', params: { section: 'operations', view: 'ops', focus: 'state' } }, coverage: 'covered' },

  // Observe Plane: split prototype tabs across the consolidated production surfaces.
  { mode: 'observe', aliases: ['cs-list', 'cascade-list'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cascade' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['cs-deep', 'cascade-deep-dive'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'inspector', focus: 'deep-dive' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['cs-cmp', 'cascade-compare'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'inspector', focus: 'compare' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['au-led', 'audit-ledger'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'audit' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['au-act', 'audit-by-actor'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'audit', focus: 'actor' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['au-sum', 'audit-summary'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'audit', focus: 'summary' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['sa-dash', 'safe-auto-dashboard'], target: { tab: 'command', params: { section: 'operations', view: 'safety' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['sa-kpr', 'safe-auto-by-keeper'], target: { tab: 'command', params: { section: 'operations', view: 'safety', focus: 'keeper' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['sa-trd', 'safe-auto-trend'], target: { tab: 'command', params: { section: 'operations', view: 'safety', focus: 'trend' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['ct-agt', 'cost-per-agent'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cost', focus: 'agent' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['ct-mtx', 'cost-matrix'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cost', focus: 'matrix' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['ct-lat', 'cost-latency'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'cost', focus: 'latency' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['hr-log', 'heuristic-log'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'heuristics', focus: 'log' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['hr-st', 'stress-board'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'stress' } }, coverage: 'covered' },
  { mode: 'observe', aliases: ['hr-mod', 'heuristic-by-module'], target: { tab: 'monitoring', params: { section: 'runtime', view: 'heuristics', focus: 'module' } }, coverage: 'covered' },

  // Cognition Plane: production view tabs show available data and blocked backend gaps.
  { mode: 'cognition', aliases: ['ki-bdi', 'keeper-bdi'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'keeper', focus: 'bdi' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ki-acc', 'keeper-tool-access'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'keeper', focus: 'tool-access' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ki-stat', 'keeper-token-stats'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'token-stats' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['dc-str', 'decisions-stream'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'decisions' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['dc-mem', 'memory-entries'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'memory', focus: 'entries' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ep-card', 'episodes-cards'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'episodes' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ep-lrn', 'episodes-learnings'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'episodes' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ar-lst', 'ar-loops'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'autoresearch' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ar-fnd', 'ar-finding-card'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'autoresearch', focus: 'finding' } }, coverage: 'covered' },
  { mode: 'cognition', aliases: ['ar-flw', 'ar-flow'], target: { tab: 'monitoring', params: { section: 'cognition', view: 'autoresearch', focus: 'flow' } }, coverage: 'covered' },

  // IDE Plane.
  { mode: 'ide', aliases: ['edit', 'source'], target: { tab: 'code', params: { section: 'ide-shell', view: 'source' } }, coverage: 'covered' },
  { mode: 'ide', aliases: ['review', 'pr-thread'], target: { tab: 'code', params: { section: 'ide-shell', view: 'unified', focus: 'review' } }, coverage: 'covered' },
  { mode: 'ide', aliases: ['merge', 'split', 'split-diff'], target: { tab: 'code', params: { section: 'ide-shell', view: 'split-diff' } }, coverage: 'covered' },
  { mode: 'ide', aliases: ['graph', 'git-graph'], target: { tab: 'workspace', params: { section: 'repositories', view: 'graph' } }, coverage: 'covered' },
  { mode: 'ide', aliases: ['search', 'find'], target: { tab: 'code', params: { section: 'ide-shell', view: 'source', find: 'open' } }, coverage: 'covered' },
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

export function normalizeCognitiveMode(input: string | null | undefined): CognitiveMode | null {
  const normalized = input?.trim().toLowerCase()
  if (!normalized) return null
  return Object.prototype.hasOwnProperty.call(COGNITIVE_MODE_TARGETS, normalized)
    ? normalized as CognitiveMode
    : null
}

export function cognitiveModeForCockpitMode(
  input: CockpitMode | string | null | undefined,
): CognitiveMode | null {
  const cockpitMode = normalizeCockpitMode(input)
  if (cockpitMode) return COCKPIT_MODE_TO_COGNITIVE_MODE.get(cockpitMode) ?? null
  return normalizeCognitiveMode(input)
}

export function cognitiveModeForRoute(
  tab: TabId,
  params: Record<string, string> = {},
): CognitiveMode {
  const explicitMode = cognitiveModeForCockpitMode(params.mode ?? params.plane)
  if (explicitMode) return explicitMode

  if (tab === 'code') {
    return params.view === 'split-diff' ? 'split' : 'code'
  }
  if (tab === 'workspace' && params.section === 'repositories' && params.view === 'graph') {
    return 'explode'
  }
  return 'cockpit'
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
