// MASC Dashboard — Status Surface
// Monitor is keeper-fleet first. Tool, runtime/runtime, evidence, and
// hidden diagnostic/deep-link routes remain routeable through this dispatcher.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { sectionItemsForTab, visibleSectionItemsForTab } from '../config/navigation'
import { LoadingState } from './common/feedback-state'
import { RouteLink } from './common/route-link'
import { SurfaceHeader } from './common/surface-header'

export type StatusSection =
  | 'observatory' | 'journey' | 'agents' | 'runtime'
  | 'internal-agents'
  | 'fleet-health' | 'transport-health'
  | 'feature-health'

function monitorSectionItem(section: string | undefined) {
  if (!section) return undefined
  return sectionItemsForTab('monitoring').find(item => item.params.section === section)
}

function isStatusSection(section: string | undefined): section is StatusSection {
  return monitorSectionItem(section) !== undefined
}

export function isMonitorLane(section: StatusSection): boolean {
  const item = monitorSectionItem(section)
  return item !== undefined && item.hidden !== true
}

export function isHiddenDiagnostic(section: StatusSection): boolean {
  return !isMonitorLane(section)
}

const LazyAgentsUnified = lazy(async () => ({
  default: (await import('./agents-unified')).AgentsUnified,
}))
const LazyRuntimePanel = lazy(async () => ({
  default: (await import('./runtime-panel')).RuntimePanel,
}))
const LazyInternalAgentsMonitor = lazy(async () => ({
  default: (await import('./internal-agents-monitor')).InternalAgentsMonitor,
}))
const LazyFleetHealthPanel = lazy(async () => ({
  default: (await import('./fleet-health-panel')).FleetHealthPanel,
}))
const LazyTransportHealthPanel = lazy(async () => ({
  default: (await import('./transport-health')).TransportHealthPanel,
}))
const LazyFeatureHealth = lazy(async () => ({
  default: (await import('./feature-health')).FeatureHealth,
}))
const LazyObservatory = lazy(async () => ({
  default: (await import('./observatory/observatory')).Observatory,
}))
const LazyJourneyPanel = lazy(async () => ({
  default: (await import('./journey-panel')).JourneyPanel,
}))

function sectionFallback(label: string) {
  return html`<${LoadingState}>Loading ${label}...<//>`
}

export function sectionLabel(section: StatusSection): string {
  return monitorSectionItem(section)?.label ?? section
}

function renderSection(section: StatusSection) {
  switch (section) {
    case 'observatory':
      return html`<${LazyObservatory} />`
    case 'journey':
      return html`<${LazyJourneyPanel} />`
    case 'runtime':
      return html`<${LazyRuntimePanel} />`
    case 'internal-agents':
      return html`<${LazyInternalAgentsMonitor} />`
    case 'fleet-health':
      return html`<${LazyFleetHealthPanel} />`
    case 'transport-health':
      return html`<${LazyTransportHealthPanel} />`
    case 'feature-health':
      return html`<${LazyFeatureHealth} />`
    case 'agents':
      return html`<${LazyAgentsUnified} />`
  }
}

export function normalizeStatusSection(section: string | undefined): StatusSection {
  if (isStatusSection(section)) return section
  return 'agents'
}

function currentSection(): StatusSection {
  return normalizeStatusSection(route.value.params.section)
}

/* Every Monitor section except the 'agents' landing was routable but had no
   rendered link anywhere in the app. The nav that used to draw section
   sublists ([SideRail]) is never mounted — the live rail ([NavRailV2]) has no
   section concept, and [SurfaceHeader] only renders the current section as a
   breadcrumb label. So 'internal-agents', which carries librarian and judge
   runs, could only be reached by typing #monitoring?section=internal-agents.
   This strip is that missing link, and it renders on the landing too — the
   'agents' branch below returns before [SurfaceHeader], so putting it there
   would have left the one screen users actually arrive at without a way out. */
function MonitorSectionNav({ current }: { current: StatusSection }) {
  const items = visibleSectionItemsForTab('monitoring')
  if (items.length < 2) return null
  return html`
    <nav
      class="flex flex-wrap items-center gap-1 border-b border-[var(--color-border-divider)] pb-2"
      aria-label="Monitor sections"
      data-testid="monitor-section-nav"
    >
      ${items.map(item => {
        const active = item.params.section === current
        return html`
          <${RouteLink}
            tab="monitoring"
            params=${item.params}
            title=${item.description}
            ariaCurrent=${active ? 'page' : undefined}
            class="rounded-[var(--r-0)] border px-2 py-0.5 font-mono text-[var(--fs-10)] uppercase leading-5 tracking-[var(--track-sub)] cursor-pointer transition-[background-color,border-color,color] duration-[var(--t-med)] ${active
              ? 'border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--select)]'
              : 'border-transparent !text-[var(--color-fg-muted)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:!text-[var(--color-fg-primary)]'}"
          >
            ${item.label}
          <//>
        `
      })}
    </nav>
  `
}

export function Status() {
  const section = currentSection()

  // Fleet and keeper detail both own their header and scroll contract. A
  // generic SurfaceHeader above the fleet duplicated its title and wrapped the
  // standalone full-height roster in a second padded card.
  if (section === 'agents') {
    // The roster owns a full-height scroll contract, so the strip is a fixed
    // row above a min-h-0 flex child rather than an extra wrapper card.
    return html`
      <div class="v2-monitoring-surface flex h-full min-h-0 flex-col gap-3">
        <${MonitorSectionNav} current=${section} />
        <div class="min-h-0 flex-1">
          <${Suspense} fallback=${sectionFallback(sectionLabel('agents'))}>
            <${LazyAgentsUnified} />
          <//>
        </div>
      </div>
    `
  }

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-5">
      <${MonitorSectionNav} current=${section} />
      <${SurfaceHeader} />
      <div class="transition-opacity duration-[var(--t-slow)]">
        <${Suspense} fallback=${sectionFallback(sectionLabel(section))}>
          ${renderSection(section)}
        <//>
      </div>
    </div>
  `
}
