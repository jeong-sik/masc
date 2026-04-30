// MASC Dashboard — Status Surface (Phase 2+4: fleet-health + runtime unified)
// Read-only observability surfaces: live, observatory, journey, agents, runtime,
// fleet-health (FilterChips unified panel), memory-subsystems.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { route } from '../router'
import { LoadingState } from './common/feedback-state'

type StatusSection =
  | 'live' | 'observatory' | 'journey' | 'git-graph' | 'agents' | 'runtime' | 'fleet-health'
  | 'cascade-inspector'
  | 'safe-autonomy'
  | 'memory-subsystems' | 'attribution'
  | 'cost'

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
const LazyLive = lazy(async () => ({
  default: (await import('./live')).Live,
}))
const LazyAttributionPanel = lazy(async () => ({
  default: (await import('./attribution-panel')).AttributionPanel,
}))
const LazyJourneyPanel = lazy(async () => ({
  default: (await import('./journey-panel')).JourneyPanel,
}))
const LazyGitGraphPanel = lazy(async () => ({
  default: (await import('./git-graph-panel')).GitGraphPanel,
}))
const LazySafeAutonomyPanel = lazy(async () => ({
  default: (await import('./safe-autonomy')).SafeAutonomyPanel,
}))
const LazyCostDashboard = lazy(async () => ({
  default: (await import('./cost-dashboard')).CostDashboard,
}))
const LazyCascadeInspector = lazy(async () => ({
  default: (await import('./cascade-inspector')).CascadeInspector,
}))

function sectionFallback(label: string) {
  return html`<${LoadingState}>${label} 불러오는 중...<//>`
}

function sectionLabel(section: StatusSection): string {
  switch (section) {
    case 'live':
      return '라이브 협업'
    case 'observatory':
      return '관찰소'
    case 'journey':
      return '여정'
    case 'git-graph':
      return 'Git 그래프'
    case 'runtime':
      return '런타임'
    case 'fleet-health':
      return '플릿 상태'
    case 'safe-autonomy':
      return '안전 자율성'
    case 'memory-subsystems':
      return '메모리 서브시스템'
    case 'attribution':
      return '기여 분석'
    case 'agents':
      return '에이전트 상태'
    case 'cost':
      return '비용 / 지연'
    case 'cascade-inspector':
      return 'Cascade 검사기'
  }
}

function renderSection(section: StatusSection) {
  switch (section) {
    case 'live':
      return html`<${LazyLive} />`
    case 'observatory':
      return html`<${LazyObservatory} />`
    case 'journey':
      return html`<${LazyJourneyPanel} />`
    case 'git-graph':
      return html`<${LazyGitGraphPanel} />`
    case 'runtime':
      return html`<${LazyRuntimePanel} />`
    case 'fleet-health':
      return html`<${LazyFleetHealthPanel} />`
    case 'safe-autonomy':
      return html`<${LazySafeAutonomyPanel} />`
    case 'memory-subsystems':
      return html`<${LazyMemorySubsystems} />`
    case 'attribution':
      return html`<${LazyAttributionPanel} />`
    case 'agents':
      return html`<${LazyAgentsUnified} />`
    case 'cost':
      return html`<${LazyCostDashboard} />`
    case 'cascade-inspector':
      return html`<${LazyCascadeInspector} />`
  }
}

function currentSection(): StatusSection {
  const section = route.value.params.section
  if (
    section === 'observatory'
    || section === 'live'
    || section === 'journey'
    || section === 'git-graph'
    || section === 'runtime'
    || section === 'fleet-health'
    || section === 'safe-autonomy'
    || section === 'memory-subsystems'
    || section === 'attribution'
    || section === 'cost'
    || section === 'cascade-inspector'
  ) return section
  return 'agents'
}

export function Status() {
  const section = currentSection()

  return html`
    <div class="flex flex-col gap-5">
      <div class="transition-opacity duration-300">
        <${Suspense} fallback=${sectionFallback(sectionLabel(section))}>
          ${renderSection(section)}
        <//>
      </div>
    </div>
  `
}
