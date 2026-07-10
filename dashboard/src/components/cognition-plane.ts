import { html } from 'htm/preact'
import { navigate, route } from '../router'
import { FilterChips } from './common/filter-chips'
import { KeeperDecisionsStream } from './keeper-decisions-stream'
import { KeeperCognitionInspector } from './keeper-cognition-inspector'
import { KeeperTokenStats } from './keeper-token-stats'
import { MemorySubsystems } from './memory-subsystems'
import { RouteLink } from './common/route-link'

type CognitionView =
  | 'overview'
  | 'keeper'
  | 'token-stats'
  | 'decisions'
  | 'memory'
  | 'episodes'

const COGNITION_VIEWS: CognitionView[] = [
  'overview',
  'keeper',
  'token-stats',
  'decisions',
  'memory',
  'episodes',
]

const VIEW_CHIPS: Array<{ key: CognitionView; label: string; title?: string }> = [
  { key: 'overview', label: 'Overview' },
  { key: 'keeper', label: 'Keeper' },
  { key: 'token-stats', label: 'Token Stats' },
  { key: 'decisions', label: 'Decisions' },
  { key: 'memory', label: 'Memory' },
  { key: 'episodes', label: 'Episodes' },
]

function currentView(): CognitionView {
  const raw = route.value.params.view
  return raw && (COGNITION_VIEWS as string[]).includes(raw)
    ? raw as CognitionView
    : 'overview'
}

function updateViewParam(view: CognitionView): void {
  if (view === currentView()) return
  const next: Record<string, string> = { ...route.value.params, section: 'cognition' }
  delete next.focus
  if (view === 'overview') {
    delete next.view
  } else {
    next.view = view
  }
  navigate('monitoring', next)
}

const OVERVIEW_LINKS: Array<{
  label: string
  detail: string
  params: Record<string, string>
}> = [
  {
    label: 'Keeper',
    detail: 'Tool access and memory inspection',
    params: { section: 'cognition', view: 'keeper' },
  },
  {
    label: 'Token Stats',
    detail: 'Keeper token budget and spend',
    params: { section: 'cognition', view: 'token-stats' },
  },
  {
    label: 'Decisions',
    detail: 'Decision stream and rationale',
    params: { section: 'cognition', view: 'decisions' },
  },
  {
    label: 'Memory',
    detail: 'Memory subsystem entries',
    params: { section: 'cognition', view: 'memory' },
  },
  {
    label: 'Episodes',
    detail: 'Episode-focused memory view',
    params: { section: 'cognition', view: 'episodes' },
  },
]

function CognitionOverview() {
  return html`
    <section class="grid gap-3 md:grid-cols-2" aria-label="Cognition overview">
      ${OVERVIEW_LINKS.map(item => html`
        <${RouteLink}
          key=${item.label}
          tab="monitoring"
          params=${item.params}
          class="min-w-0 rounded-[var(--r-1)] border border-card-border/70 bg-[var(--color-bg-surface)] p-3 transition-colors hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-elevated)]"
        >
          <div class="text-sm font-semibold text-text-strong">${item.label}</div>
          <div class="mt-1 text-xs text-text-muted">${item.detail}</div>
        <//>
      `)}
      <${RouteLink}
        tab="monitoring"
        params=${{ section: 'agents' }}
        class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-3 transition-colors hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-elevated)] md:col-span-2"
      >
        <div class="text-sm font-semibold text-text-strong">Keeper Fleet</div>
        <div class="mt-1 text-xs text-text-muted">Roster, keepers, cognition entry points, and FSM views live in one fleet surface.</div>
      <//>
    </section>
  `
}

export function CognitionPlane() {
  const view = currentView()

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-5">
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
      ` : view === 'memory' ? html`
        <${MemorySubsystems} focus=${route.value.params.focus} />
      ` : view === 'episodes' ? html`
        <${MemorySubsystems} focus="episodes" />
      ` : html`
        <${CognitionOverview} />
      `}
    </div>
  `
}
