import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { PanelRightClose, PanelRightOpen } from 'lucide-preact'
import {
  createLayeredOverlay,
  type OverlayLayer,
} from '../../../design-system/headless-core/layered-overlay'
import { useLayeredOverlay } from '../../../design-system/headless-preact/use-layered-overlay'
import { navigate } from '../../router'
import { CommandBar, type CommandBarAction } from '../common/command-bar'
import {
  ideContextFocus,
  type IdeContextFocus,
  type IdeContextFocusRouteLink,
} from './ide-state'

// Phase 1 PR-3: IDE editor toolbar — view tabs + LAYERS toggle.
// View tabs (SOURCE / SPLIT DIFF / UNIFIED / BLAME) are local UI state
// here; deep linking + editor mode wiring lands in Phase 2 PR-5 once
// the editor itself is real. The LAYERS toggle uses the RFC 0020
// controller from headless-core; overlay rendering still arrives in
// PR-5+ alongside the data sources for each layer.

type ViewTab = 'source' | 'split-diff' | 'unified' | 'blame'

const VIEW_TABS: ReadonlyArray<{ readonly id: ViewTab; readonly label: string }> = [
  { id: 'source', label: 'SOURCE' },
  { id: 'split-diff', label: 'SPLIT DIFF' },
  { id: 'unified', label: 'UNIFIED' },
  { id: 'blame', label: 'BLAME' },
]

const TOOLBAR_BUTTON_BASE =
  'v2-ide-action h-7 shrink-0 cursor-pointer rounded-[var(--r-1)] px-2 font-mono text-2xs uppercase tracking-[var(--track-caps)] transition-colors'

const VIEW_TAB_BASE = 'ide-v2-view'

// 'tools' / 'approve' / 'runtime' / 'explode' were removed (masc#24069 #49):
// they rendered as toggleable chips but had no backing data source or render
// branch — see ide-editor-blame.ts's IDE_LAYER_ORDER comment for detail. The
// 'keeper-trace' entry's `conflictsWith: ['runtime']` (RFC-0028 §10) is
// dropped with 'runtime': there is nothing left for it to conflict with.
export const IDE_LAYERS: ReadonlyArray<OverlayLayer> = [
  { kind: 'time', label: 'Time', description: '변경 timestamp gradient' },
  { kind: 'parallel', label: 'Parallel', description: '동시 keeper 작업 표시' },
  { kind: 'notes', label: 'Notes', description: 'NOTE/SUGGEST 마커' },
  {
    kind: 'keeper-trace',
    label: 'Trace',
    description: '3-source stitched gutter chip (anchored-thread / runtime-hop / decision-log)',
  },
]

export const IDE_LAYER_LABELS = new Map(IDE_LAYERS.map(layer => [layer.kind, layer.label]))
export const REVIEW_FOCUS_LAYERS = ['keeper-trace', 'notes'] as const

// 'time' / 'parallel' read per-line git-blame ownership data
// (ide-data-workspace-store.ts fetchGitBlame) that is only populated when
// the editor is showing the BLAME view. Toggling either in another view
// previously activated a layer with no data to render — a silent no-op.
// Gated here so the toolbar disables the affordance instead.
const VIEW_GATED_LAYER_KINDS: ReadonlySet<string> = new Set(['time', 'parallel'])

export function layerAvailableInView(kind: string, view: ViewTab): boolean {
  return !VIEW_GATED_LAYER_KINDS.has(kind) || view === 'blame'
}

export function availableLayersForView(
  layers: ReadonlySet<string>,
  view: ViewTab,
): ReadonlySet<string> {
  return new Set(Array.from(layers).filter(kind => layerAvailableInView(kind, view)))
}

interface IdeToolbarProps {
  readonly activeView: ViewTab
  readonly activeLayers: ReadonlySet<string>
  readonly onViewChange: (id: ViewTab) => void
  readonly onLayersChange: (active: ReadonlySet<string>) => void
  readonly railsCollapsed?: boolean
  readonly onRailsToggle?: () => void
  readonly onTerminalOpen?: () => void
  readonly onFindOpen?: () => void
}

export type ToolbarContextRouteGroupId = 'code' | 'planning' | 'board' | 'repo' | 'runtime' | 'other'

export interface ToolbarContextRouteGroup {
  readonly id: ToolbarContextRouteGroupId
  readonly label: string
  readonly count: number
  readonly evidence: string
  readonly routeLink: IdeContextFocusRouteLink
}

const TOOLBAR_ROUTE_GROUP_ORDER: ReadonlyArray<ToolbarContextRouteGroupId> = [
  'code',
  'planning',
  'board',
  'repo',
  'runtime',
  'other',
]

const TOOLBAR_ROUTE_GROUP_LABELS: Readonly<Record<ToolbarContextRouteGroupId, string>> = {
  code: 'Code',
  planning: 'Plan',
  board: 'Board',
  repo: 'Repo',
  runtime: 'Runtime',
  other: 'Other',
}

export function IdeToolbar({
  activeView,
  activeLayers,
  onViewChange,
  onLayersChange,
  railsCollapsed = false,
  onRailsToggle,
  onTerminalOpen,
  onFindOpen,
}: IdeToolbarProps) {
  const controller = useMemo(() => {
    const next = createLayeredOverlay(IDE_LAYERS)
    next.setActive(activeLayers)
    return next
  }, [])
  const { active, isActive } = useLayeredOverlay(controller)
  const [contextFocus, setContextFocus] = useState(ideContextFocus.value)
  const availableLayers = IDE_LAYERS.filter(layer => layerAvailableInView(layer.kind, activeView))

  useEffect(() => {
    controller.setActive(activeLayers)
  }, [controller, activeLayers])

  useEffect(() => {
    const unsub = ideContextFocus.subscribe(focus => setContextFocus(focus))
    return () => unsub()
  }, [])

  const handleLayerToggle = (kind: string) => {
    controller.toggle(kind)
    onLayersChange(controller.active())
  }

  const commandActions: CommandBarAction[] = [
    ...VIEW_TABS.map(tab => ({
      id: `view-${tab.id}`,
      title: `View: ${tab.label}`,
      keywords: `${tab.id} ${tab.label} editor mode`,
      handler: () => onViewChange(tab.id),
    })),
    ...availableLayers.map(layer => ({
      id: `layer-${layer.kind}`,
      title: `${isActive(layer.kind) ? 'Hide' : 'Show'} ${layer.label} layer`,
      keywords: `toggle ${layer.kind} ${layer.description}`,
      handler: () => handleLayerToggle(layer.kind),
    })),
    ...(onRailsToggle
      ? [{
          id: 'rail-toggle',
          title: railsCollapsed ? 'Show IDE rails' : 'Hide IDE rails',
          keywords: 'rails inspector activity conversation layout wide center',
          handler: onRailsToggle,
        }]
      : []),
    ...(onTerminalOpen
      ? [{
          id: 'terminal-open',
          title: 'Open Keeper Terminal',
          keywords: 'terminal shell keeper output',
          handler: onTerminalOpen,
        }]
      : []),
    ...(onFindOpen
      ? [{
          id: 'find-open',
          title: 'Find in Current File',
          keywords: 'find search current file editor match',
          handler: onFindOpen,
        }]
      : []),
    ...contextCommandActions(contextFocus),
  ]

  return html`
    <div
      role="toolbar"
      aria-label="IDE editor toolbar"
      data-testid="ide-toolbar"
      class="ide-toolbar v2-ide-toolbar"
      data-has-rails=${onRailsToggle ? 'true' : 'false'}
    >
      <div
        class="ide-toolbar-tabs flex min-w-0 gap-1.5 overflow-x-auto pb-0.5"
        role="tablist"
        aria-label="View mode"
        data-testid="ide-toolbar-tabs"
      >
        ${VIEW_TABS.map(tab => html`
          <button
            type="button"
            role="tab"
            aria-selected=${tab.id === activeView ? 'true' : 'false'}
            tabIndex=${tab.id === activeView ? 0 : -1}
            onClick=${() => onViewChange(tab.id)}
            class=${`${TOOLBAR_BUTTON_BASE} ${VIEW_TAB_BASE}`}
          >${tab.label}</button>
        `)}
      </div>
      <div class="ide-toolbar-command-cluster">
        <${CommandBar}
          actions=${commandActions}
          placeholder="Run IDE command..."
          testId="ide-command-bar"
          className="min-w-0"
          inputClassName="h-7 w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 font-mono text-2xs text-[var(--color-fg-primary)] outline-none transition-colors placeholder:text-[var(--color-fg-disabled)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)]"
        />
        <${ToolbarContextFocus} focus=${contextFocus} />
      </div>
      ${onRailsToggle ? html`
        <button
          type="button"
          class="v2-ide-action"
          aria-pressed=${railsCollapsed ? 'true' : 'false'}
          onClick=${onRailsToggle}
          title=${railsCollapsed ? 'Show IDE rails' : 'Hide IDE rails'}
          style=${{
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 'var(--sp-1)',
            minWidth: '4rem',
            height: '26px',
            padding: '2px 8px',
            background: railsCollapsed ? 'var(--color-bg-elevated)' : 'transparent',
            color: railsCollapsed ? 'var(--color-accent-fg)' : 'var(--color-fg-secondary)',
            border: '1px solid',
            borderColor: railsCollapsed ? 'var(--color-accent-fg)' : 'var(--color-border-default)',
            borderRadius: 'var(--r-1)',
            font: 'var(--type-body)',
            cursor: 'pointer',
            whiteSpace: 'nowrap',
          }}
        >
          ${railsCollapsed
            ? html`<${PanelRightOpen} size=${13} aria-hidden="true" />`
            : html`<${PanelRightClose} size=${13} aria-hidden="true" />`}
          <span>Rails</span>
        </button>
      ` : null}
      <div
        aria-label="Layers (multi-select)"
        data-testid="ide-toolbar-layers"
        class="ide-toolbar-layers flex min-w-0 items-center gap-1.5 overflow-x-auto pb-0.5 font-mono text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]"
      >
        <span class="shrink-0">LAYERS</span>
        ${availableLayers.map(layer => html`
          <button
            type="button"
            aria-pressed=${isActive(layer.kind) ? 'true' : 'false'}
            onClick=${() => handleLayerToggle(layer.kind)}
            title=${layer.description}
            class=${TOOLBAR_BUTTON_BASE}
            style=${{
              background: isActive(layer.kind)
                ? 'var(--color-bg-elevated)'
                : 'transparent',
              color: isActive(layer.kind)
                ? 'var(--color-fg-primary)'
                : 'var(--color-fg-secondary)',
              border: '1px solid',
              borderColor: isActive(layer.kind)
                ? 'var(--color-accent-fg)'
                : 'var(--color-border-default)',
            }}
          >${layer.label}</button>
        `)}
        ${availableLayers.some(layer => active.has(layer.kind))
          ? html`<span class="shrink-0 text-[var(--color-fg-disabled)]">${availableLayers.filter(layer => active.has(layer.kind)).length} active</span>`
          : null}
      </div>
    </div>
  `
}

function contextCommandActions(focus: IdeContextFocus | null): CommandBarAction[] {
  if (!focus?.route_links || focus.route_links.length === 0) return []
  return focus.route_links.map(link => ({
    id: `context-${link.id}`,
    title: `Open context: ${link.label} · ${toolbarContextLinkEvidence(link)}`,
    keywords: [
      'context focus route link',
      focus.surface,
      focus.label,
      focus.keeper_id ?? '',
      link.evidence,
    ].join(' '),
    handler: () => openToolbarContextRouteLink(link),
  }))
}

function ToolbarContextFocus({
  focus,
}: {
  readonly focus: IdeContextFocus | null
}) {
  if (!focus) return null
  const lineLabel = focus.line !== undefined ? `L${focus.line}` : null
  const routeLinks = focus.route_links ?? []
  const routeGroups = deriveToolbarContextRouteGroups(focus)
  return html`
    <div
      class="ide-toolbar-context-focus"
      data-testid="ide-toolbar-context-focus"
      aria-label=${toolbarContextAriaLabel(focus)}
      title=${`${focus.file_path}${focus.line !== undefined ? `:${focus.line}` : ''}`}
    >
      <span>${focus.surface}</span>
      ${lineLabel ? html`<span>${lineLabel}</span>` : null}
      <strong>${focus.label}</strong>
      ${focus.keeper_id ? html`<span>keeper ${focus.keeper_id}</span>` : null}
      ${routeGroups.length > 0 ? html`
        <div class="ide-toolbar-context-route-groups" aria-label="Current context surface groups">
          ${routeGroups.map(group => html`
            <span
              key=${group.id}
              title=${group.evidence}
              aria-label=${`${group.label}: ${group.count} route ${group.count === 1 ? 'link' : 'links'}`}
            >
              <button
                type="button"
                class="ide-toolbar-context-route-group-action v2-ide-action"
                title=${group.evidence}
                aria-label=${`Open ${group.evidence}`}
                onClick=${() => openToolbarContextRouteLink(group.routeLink)}
              >
                <span>${group.label}</span>
                <span>${group.count}</span>
              </button>
            </span>
          `)}
        </div>
      ` : null}
      ${routeLinks.length > 0 ? html`
        <div class="ide-toolbar-context-links" aria-label="Current context route links">
          ${routeLinks.map(link => html`
            <button
              key=${link.id}
              type="button"
              class="v2-ide-action"
              title=${link.evidence}
              aria-label=${`Open ${link.evidence}`}
              onClick=${() => openToolbarContextRouteLink(link)}
            >
              <span class="ide-toolbar-context-link-label">${link.label}</span>
              <span class="ide-toolbar-context-link-evidence">${toolbarContextLinkEvidence(link)}</span>
            </button>
          `)}
        </div>
      ` : null}
    </div>
  `
}

function openToolbarContextRouteLink(link: IdeContextFocusRouteLink): void {
  navigate(link.tab, link.params)
}

function toolbarContextAriaLabel(focus: IdeContextFocus): string {
  const line = focus.line !== undefined ? ` line ${focus.line}` : ''
  const keeper = focus.keeper_id ? `, keeper ${focus.keeper_id}` : ''
  const links = focus.route_links?.length
    ? `, ${focus.route_links.length} route links`
    : ''
  return `Current IDE context: ${focus.surface}${line}, ${focus.label}${keeper}${links}`
}

export function deriveToolbarContextRouteGroups(
  focus: IdeContextFocus | null,
): ReadonlyArray<ToolbarContextRouteGroup> {
  const links = focus?.route_links ?? []
  const grouped = new Map<ToolbarContextRouteGroupId, IdeContextFocusRouteLink[]>()
  for (const link of links) {
    const groupId = toolbarContextRouteGroupId(link)
    const current = grouped.get(groupId)
    if (current) current.push(link)
    else grouped.set(groupId, [link])
  }
  return TOOLBAR_ROUTE_GROUP_ORDER.flatMap(groupId => {
    const groupLinks = grouped.get(groupId)
    if (!groupLinks || groupLinks.length === 0) return []
    return [{
      id: groupId,
      label: TOOLBAR_ROUTE_GROUP_LABELS[groupId],
      count: groupLinks.length,
      evidence: groupLinks.map(link => link.evidence).join(' / '),
      routeLink: groupLinks[0]!,
    }]
  })
}

function toolbarContextRouteGroupId(link: IdeContextFocusRouteLink): ToolbarContextRouteGroupId {
  const section = link.params.section?.toLowerCase()
  const label = link.label.toLowerCase()
  if (link.tab === 'code' || label === 'code') return 'code'
  if (section === 'planning' || label === 'goal' || label === 'task') return 'planning'
  if (section === 'board' || label === 'board' || label === 'comment') return 'board'
  if (section === 'repositories' || label === 'pr' || label === 'git') return 'repo'
  if (link.tab === 'monitoring' || label === 'log' || label === 'telemetry' || label === 'keeper') {
    return 'runtime'
  }
  return 'other'
}

function toolbarContextLinkEvidence(link: IdeContextFocusRouteLink): string {
  const evidence = link.evidence.trim()
  const labelPrefix = `${link.label} `
  if (evidence.startsWith(labelPrefix)) return evidence.slice(labelPrefix.length)
  const scoped = evidence.split(' · ').slice(1).join(' · ')
  return scoped || evidence
}
