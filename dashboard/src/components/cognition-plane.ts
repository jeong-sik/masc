import { html } from 'htm/preact'
import { navigate, route } from '../router'
import { AgentsUnified } from './agents-unified'
import { Autoresearch } from './autoresearch'
import { FilterChips } from './common/filter-chips'
import { KeeperDecisionsStream } from './keeper-decisions-stream'
import { KeeperCognitionInspector } from './keeper-cognition-inspector'
import { KeeperTokenStats } from './keeper-token-stats'
import { MemorySubsystems } from './memory-subsystems'

type CognitionView = 'overview' | 'keeper' | 'token-stats' | 'decisions' | 'memory' | 'episodes' | 'autoresearch'

const COGNITION_VIEWS: CognitionView[] = [
  'overview',
  'keeper',
  'token-stats',
  'decisions',
  'memory',
  'episodes',
  'autoresearch',
]

const VIEW_CHIPS: Array<{ key: CognitionView; label: string; title?: string }> = [
  { key: 'overview', label: 'Overview' },
  { key: 'keeper', label: 'Keeper' },
  { key: 'token-stats', label: 'Token Stats' },
  { key: 'decisions', label: 'Decisions' },
  { key: 'memory', label: 'Memory' },
  { key: 'episodes', label: 'Episodes' },
  { key: 'autoresearch', label: 'Autoresearch' },
]

function currentView(): CognitionView {
  const raw = route.value.params.view
  return raw && (COGNITION_VIEWS as string[]).includes(raw)
    ? raw as CognitionView
    : 'overview'
}

function updateViewParam(view: CognitionView): void {
  const next: Record<string, string> = { ...route.value.params, section: 'cognition' }
  if (view === 'overview') {
    delete next.view
  } else {
    next.view = view
  }
  navigate('monitoring', next)
}

export function CognitionPlane() {
  const view = currentView()

  return html`
    <div class="flex flex-col gap-5">
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="sm"
        tone="accent"
      />

      ${view === 'keeper' ? html`
        <${KeeperCognitionInspector} />
      ` : view === 'token-stats' ? html`
        <${KeeperTokenStats} />
      ` : view === 'decisions' ? html`
        <${KeeperDecisionsStream} />
      ` : view === 'memory' || view === 'episodes' ? html`
        <${MemorySubsystems} />
      ` : view === 'autoresearch' ? html`
        <${Autoresearch} />
      ` : html`
        <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
          <${KeeperTokenStats} />
          <${Autoresearch} />
        </div>
        <${AgentsUnified} />
        <${MemorySubsystems} />
      `}
    </div>
  `
}
