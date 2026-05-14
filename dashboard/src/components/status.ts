// MASC Dashboard — Status Surface (Phase 2+4: fleet-health + runtime unified)
// Read-only observability surfaces: journey, agents, runtime, fleet-health,
// plus hidden diagnostic observatory route.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { LoadingState } from './common/feedback-state'
import { JourneyPanel } from './journey-panel'

export type StatusSection =
  | 'observatory' | 'journey' | 'agents' | 'runtime' | 'goal-loop' | 'fleet-health'
  | 'cognition'

const LazyAgentsUnified = lazy(async () => ({
  default: (await import('./agents-unified')).AgentsUnified,
}))
const LazyRuntimePanel = lazy(async () => ({
  default: (await import('./runtime-panel')).RuntimePanel,
}))
const LazyFleetHealthPanel = lazy(async () => ({
  default: (await import('./fleet-health-panel')).FleetHealthPanel,
}))
const LazyGoalLoopPanel = lazy(async () => ({
  default: (await import('./goal-loop-panel')).GoalLoopPanel,
}))
const LazyObservatory = lazy(async () => ({
  default: (await import('./observatory/observatory')).Observatory,
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
    case 'goal-loop':
      return 'GOAL LOOP'
    case 'fleet-health':
      return 'Fleet Health'
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
      return html`<${JourneyPanel} />`
    case 'runtime':
      return html`<${LazyRuntimePanel} />`
    case 'goal-loop':
      return html`<${LazyGoalLoopPanel} />`
    case 'fleet-health':
      return html`<${LazyFleetHealthPanel} />`
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
    || section === 'goal-loop'
    || section === 'fleet-health'
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
