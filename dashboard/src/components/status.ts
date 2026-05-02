// MASC Dashboard — Status Surface (Phase 2+4: fleet-health + runtime unified)
// Read-only observability surfaces: journey, agents, runtime, fleet-health,
// plus hidden diagnostic observatory/memory-subsystems routes.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { LoadingState } from './common/feedback-state'

export type StatusSection =
  | 'observatory' | 'journey' | 'agents' | 'runtime' | 'fleet-health'
  | 'memory-subsystems' | 'cognition'

const LazyAgentsUnified = lazy(async () => ({
  default: (await import('./agents-unified')).AgentsUnified,
}))
const LazyRuntimePanel = lazy(async () => ({
  default: (await import('./runtime-panel')).RuntimePanel,
}))
const LazyMemorySubsystems = lazy(async () => ({
  default: (await import('./memory-subsystems')).MemorySubsystems,
}))
const LazyFleetHealthPanel = lazy(async () => ({
  default: (await import('./fleet-health-panel')).FleetHealthPanel,
}))
const LazyObservatory = lazy(async () => ({
  default: (await import('./observatory/observatory')).Observatory,
}))
const LazyJourneyPanel = lazy(async () => ({
  default: (await import('./journey-panel')).JourneyPanel,
}))
const LazyCognitionPlane = lazy(async () => ({
  default: (await import('./cognition-plane')).CognitionPlane,
}))

function sectionFallback(label: string) {
  return html`<${LoadingState}>Loading ${label}...<//>`
}

export function sectionLabel(section: StatusSection): string {
  switch (section) {
    case 'observatory':
      return 'Observatory'
    case 'journey':
      return 'Journey'
    case 'runtime':
      return 'Runtime'
    case 'fleet-health':
      return 'Fleet Health'
    case 'memory-subsystems':
      return 'Memory Subsystems'
    case 'cognition':
      return 'Cognition'
    case 'agents':
      return 'Agents'
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
    case 'fleet-health':
      return html`<${LazyFleetHealthPanel} />`
    case 'memory-subsystems':
      return html`<${LazyMemorySubsystems} />`
    case 'cognition':
      return html`<${LazyCognitionPlane} />`
    case 'agents':
      return html`<${LazyAgentsUnified} />`
  }
}

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (
    section === 'observatory'
    || section === 'journey'
    || section === 'runtime'
    || section === 'fleet-health'
    || section === 'memory-subsystems'
    || section === 'cognition'
    || section === 'agents'
  ) return section
  return 'journey'
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
