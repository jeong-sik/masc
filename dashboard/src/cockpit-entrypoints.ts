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
  explode: { tab: 'workspace', params: { section: 'repositories' } },
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
  comms: { tab: 'board' },
  observe: { tab: 'monitoring', params: { section: 'runtime' } },
  cognition: { tab: 'monitoring', params: { section: 'agents' } },
  ide: COGNITIVE_MODE_TARGETS.code,
  code: COGNITIVE_MODE_TARGETS.code,
  split: COGNITIVE_MODE_TARGETS.split,
  terminal: { tab: 'code', params: { section: 'ide-shell', view: 'source', terminal: 'open' } },
  explode: COGNITIVE_MODE_TARGETS.explode,
}

export const COCKPIT_ENTRYPOINTS: CockpitEntrypoint[] = [
  {
    mode: 'work',
    aliases: ['goal-horizon'],
    target: { tab: 'workspace', params: { section: 'planning', view: 'goal-tree' } },
    coverage: 'covered',
  },
  {
    mode: 'work',
    aliases: ['task-board'],
    target: { tab: 'workspace', params: { section: 'planning', view: 'default' } },
    coverage: 'covered',
  },
  {
    mode: 'comms',
    aliases: ['board-feed'],
    target: { tab: 'board' },
    coverage: 'covered',
  },
  {
    mode: 'comms',
    aliases: ['composer'],
    target: { tab: 'command', params: { section: 'operations', view: 'ops' } },
    coverage: 'covered',
  },
  {
    mode: 'observe',
    aliases: ['runtime'],
    target: { tab: 'monitoring', params: { section: 'runtime' } },
    coverage: 'covered',
  },
  {
    mode: 'observe',
    aliases: ['audit'],
    target: { tab: 'monitoring', params: { section: 'runtime', view: 'audit' } },
    coverage: 'covered',
  },
  {
    mode: 'observe',
    aliases: ['safety'],
    target: { tab: 'command', params: { section: 'operations', view: 'safety' } },
    coverage: 'covered',
  },
  {
    mode: 'observe',
    aliases: ['cost'],
    target: { tab: 'monitoring', params: { section: 'runtime', view: 'cost' } },
    coverage: 'covered',
  },
  {
    mode: 'cognition',
    aliases: ['keeper-cognition'],
    target: { tab: 'monitoring', params: { section: 'agents', view: 'keeper' } },
    coverage: 'covered',
  },
  {
    mode: 'ide',
    aliases: ['source'],
    target: { tab: 'code', params: { section: 'ide-shell', view: 'source' } },
    coverage: 'covered',
  },
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
  if (tab === 'workspace' && params.section === 'repositories') {
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
