import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { sectionItemsForTab } from '../config/navigation'
import { LoadingState } from './common/feedback-state'
import { SectionNav } from './common/section-nav'
import { SurfaceHeader } from './common/surface-header'

export type StatusSection =
  | 'runtime'
  | 'internal-agents'
  | 'fleet-health' | 'transport-health'
  | 'lanes' | 'skills' | 'lane-addons' | 'lane-inventory'

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
const LazyLaneAddonsPanel = lazy(async () => ({
  default: (await import('./lane-addons-panel')).LaneAddonsPanel,
}))
const LazyLaneQueuePanel = lazy(async () => ({
  default: (await import('./lanes/lane-queue-panel')).LaneQueuePanel,
}))
const LazyLaneInventoryPanel = lazy(async () => ({
  default: (await import('./lane-inventory-panel')).LaneInventoryPanel,
}))
const LazySkillsPanel = lazy(async () => ({
  default: (await import('./skills-panel')).SkillsPanel,
}))

function sectionFallback(label: string) {
  return html`<${LoadingState}>Loading ${label}...<//>`
}

export function sectionLabel(section: StatusSection): string {
  return monitorSectionItem(section)?.label ?? section
}

function renderSection(section: StatusSection) {
  switch (section) {
    case 'lane-addons':
      return html`<${LazyLaneAddonsPanel} />`
    case 'lane-inventory':
      return html`<${LazyLaneInventoryPanel} />`
    case 'lanes':
      return html`<${LazyLaneQueuePanel} />`
    case 'skills':
      return html`<${LazySkillsPanel} />`
    case 'runtime':
      return html`<${LazyRuntimePanel} />`
    case 'internal-agents':
      return html`<${LazyInternalAgentsMonitor} />`
    case 'fleet-health':
      return html`<${LazyFleetHealthPanel} />`
    case 'transport-health':
      return html`<${LazyTransportHealthPanel} />`
  }
}

export function normalizeStatusSection(section: string | undefined): StatusSection {
  if (isStatusSection(section)) return section
  return 'runtime'
}

function currentSection(): StatusSection {
  return normalizeStatusSection(route.value.params.section)
}

export function Status() {
  const section = currentSection()

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-5">
      <${SectionNav} tab="monitoring" current=${section} />
      ${section === 'lane-inventory' ? null : html`<${SurfaceHeader} />`}
      <div class="transition-opacity duration-[var(--t-slow)]">
        <${Suspense} fallback=${sectionFallback(sectionLabel(section))}>
          ${renderSection(section)}
        <//>
      </div>
    </div>
  `
}
