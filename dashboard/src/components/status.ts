// MASC Dashboard — Status Surface
// Monitor is keeper-operations first. Tool, cascade/runtime, evidence, and
// hidden diagnostic/deep-link routes remain routeable through this dispatcher.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { LoadingState } from './common/feedback-state'

export type StatusSection =
  | 'observatory' | 'journey' | 'agents' | 'runtime' | 'cascade-config'
  | 'fleet-health' | 'doctor' | 'transport-health'
  | 'feature-health'
  | 'cognition'

// Monitor sidebar exposes 4 keeper-facing lanes; the remaining sections are
// reachable only via deep links or hidden diagnostic routes. The same flag
// lives on each entry's `hidden: true` in navigation.ts — this Set mirrors
// that classification so the dispatcher and future grouped layouts can ask
// without re-reading the nav config. Source of truth stays in navigation.ts.
const MONITOR_LANE_SECTIONS: ReadonlySet<StatusSection> = new Set<StatusSection>([
  'agents',
  'fleet-health',
  'runtime',
  'observatory',
])

export function isMonitorLane(section: StatusSection): boolean {
  return MONITOR_LANE_SECTIONS.has(section)
}

export function isHiddenDiagnostic(section: StatusSection): boolean {
  return !MONITOR_LANE_SECTIONS.has(section)
}

const LazyAgentsUnified = lazy(async () => ({
  default: (await import('./agents-unified')).AgentsUnified,
}))
const LazyRuntimePanel = lazy(async () => ({
  default: (await import('./runtime-panel')).RuntimePanel,
}))
const LazyCascadeConfigPanel = lazy(async () => ({
  default: (await import('./cascade-config-panel')).CascadeConfigPanel,
}))
const LazyFleetHealthPanel = lazy(async () => ({
  default: (await import('./fleet-health-panel')).FleetHealthPanel,
}))
const LazyDoctorPanel = lazy(async () => ({
  default: (await import('./doctor-panel')).DoctorPanel,
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
const LazyCognitionPlane = lazy(async () => ({
  default: (await import('./cognition-plane')).CognitionPlane,
}))
const LazyJourneyPanel = lazy(async () => ({
  default: (await import('./journey-panel')).JourneyPanel,
}))

function sectionFallback(label: string) {
  return html`<${LoadingState}>Loading ${label}...<//>`
}

export function sectionLabel(section: StatusSection): string {
  switch (section) {
    case 'observatory':
      return 'Evidence Timeline'
    case 'journey':
      return 'Journey'
    case 'runtime':
      return 'Cascade & Runtime'
    case 'cascade-config':
      return 'Cascade Config'
    case 'fleet-health':
      return 'Tool Monitor'
    case 'doctor':
      return 'Doctor'
    case 'transport-health':
      return 'Transport Health'
    case 'feature-health':
      return 'Feature Flags'
    case 'cognition':
      return 'Keeper Cognition'
    case 'agents':
      return 'Keeper Operations'
  }
}

function renderSection(section: StatusSection) {
  switch (section) {
    case 'observatory':
      return html`<${LazyObservatory} />`
    case 'journey':
      return html`<${LazyJourneyPanel} />`
    case 'runtime':
      return html`<${LazyRuntimePanel} />`
    case 'cascade-config':
      return html`<${LazyCascadeConfigPanel} />`
    case 'fleet-health':
      return html`<${LazyFleetHealthPanel} />`
    case 'doctor':
      return html`<${LazyDoctorPanel} />`
    case 'transport-health':
      return html`<${LazyTransportHealthPanel} />`
    case 'feature-health':
      return html`<${LazyFeatureHealth} />`
    case 'cognition':
      return html`<${LazyCognitionPlane} />`
    case 'agents':
      return html`<${LazyAgentsUnified} />`
  }
}

export function normalizeStatusSection(section: string | undefined): StatusSection {
  if (
    section === 'observatory'
    || section === 'journey'
    || section === 'runtime'
    || section === 'cascade-config'
    || section === 'fleet-health'
    || section === 'doctor'
    || section === 'transport-health'
    || section === 'feature-health'
    || section === 'cognition'
    || section === 'agents'
  ) return section
  return 'agents'
}

function currentSection(): StatusSection {
  return normalizeStatusSection(route.value.params.section)
}

export function Status() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-[var(--t-slow)]">
        <${Suspense} fallback=${sectionFallback(sectionLabel(section))}>
          ${renderSection(section)}
        <//>
      </div>
    </div>
  `
}
