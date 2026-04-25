// Planning Panel — Phase 7 unified view for planning section.
// FilterChips toggle between kanban (Planning) and goal-tree (GoalTree).
// Revives GoalTree which became dead code after Phase 1 removed the
// standalone goals section.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { route } from '../router'
import { coordinationFsmSnapshot } from '../store'
import { FilterChips } from './common/filter-chips'
import { Planning } from './goals'
import { GoalTree } from './goals/goal-tree'
import type {
  DashboardCoordinationFsmEvidence,
  DashboardCoordinationFsmRefs,
  DashboardCoordinationFsmSnapshot,
  DashboardCoordinationFsmViolation,
} from '../types'

type PlanningView = 'default' | 'goal-tree'

const PLANNING_VIEWS: PlanningView[] = ['default', 'goal-tree']

function isPlanningView(v: string | undefined): v is PlanningView {
  return !!v && (PLANNING_VIEWS as string[]).includes(v)
}

const activeView = computed<PlanningView>(() => {
  const v = route.value.params.view
  return isPlanningView(v) ? v : 'goal-tree'
})

const VIEW_CHIPS: Array<{ key: PlanningView; label: string }> = [
  { key: 'goal-tree', label: 'Goal Manager' },
  { key: 'default',   label: 'Backlog' },
]

function updateViewParam(view: PlanningView): void {
  const hash = view === 'goal-tree'
    ? '#workspace?section=planning'
    : `#workspace?section=planning&view=${view}`
  history.replaceState(null, '', hash)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

function coordinationCount(
  snapshot: DashboardCoordinationFsmSnapshot | null,
  key: 'products' | 'violations' | 'evidence' | 'warn' | 'error',
): number {
  if (!snapshot?.summary) return 0
  if (key === 'products') return snapshot.summary.products ?? 0
  if (key === 'violations') return snapshot.summary.violations ?? 0
  if (key === 'evidence') return snapshot.summary.evidence ?? snapshot.evidence?.length ?? 0
  return snapshot.summary.severity_counts?.[key] ?? 0
}

function severityToneClass(severity: string | undefined): string {
  switch (severity) {
    case 'error':
      return 'border-bad/35 bg-bad/10 text-bad'
    case 'warn':
      return 'border-warn/35 bg-warn/10 text-warn'
    default:
      return 'border-accent/25 bg-[var(--accent-10)] text-accent'
  }
}

function refsLabel(refs: DashboardCoordinationFsmRefs | undefined): string {
  if (!refs) return 'refs: -'
  const parts: string[] = []
  if (refs.goal_id) parts.push(`goal: ${refs.goal_id}`)
  if (refs.task_ids && refs.task_ids.length > 0) parts.push(`tasks: ${refs.task_ids.join(', ')}`)
  if (refs.post_ids && refs.post_ids.length > 0) parts.push(`posts: ${refs.post_ids.join(', ')}`)
  if (refs.agent_name) parts.push(`agent: ${refs.agent_name}`)
  return parts.length > 0 ? parts.join(' · ') : 'refs: -'
}

function evidenceLabel(evidence: DashboardCoordinationFsmEvidence): string {
  const source = evidence.source ?? 'evidence'
  const kind = evidence.kind ? `/${evidence.kind}` : ''
  return `${source}${kind}`
}

function CoordinationEvidenceRow({ evidence }: { evidence: DashboardCoordinationFsmEvidence }) {
  return html`
    <li class="min-w-0 rounded border border-card-border/40 bg-white/[0.03] px-2 py-1">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded border border-card-border/50 bg-black/15 px-1.5 py-0.5 text-3xs font-semibold uppercase text-text-muted">
          ${evidenceLabel(evidence)}
        </span>
        <span class="min-w-0 truncate text-2xs font-medium text-text-strong">
          ${evidence.label ?? evidence.id ?? 'evidence'}
        </span>
      </div>
      ${evidence.detail ? html`
        <div class="mt-0.5 truncate text-3xs text-text-dim" title=${evidence.detail}>${evidence.detail}</div>
      ` : null}
    </li>
  `
}

function CoordinationViolationRow({ violation }: { violation: DashboardCoordinationFsmViolation }) {
  const evidence = (violation.evidence ?? []).slice(0, 3)
  return html`
    <li class="rounded border border-card-border/60 bg-black/10 p-2">
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="rounded border px-2 py-0.5 text-3xs font-semibold uppercase ${severityToneClass(violation.severity)}">
          ${violation.severity ?? 'info'}
        </span>
        <span class="font-mono text-2xs text-text-strong">${violation.code ?? violation.axis ?? 'coordination'}</span>
        ${violation.axis ? html`<span class="text-3xs text-text-dim">${violation.axis}</span>` : null}
      </div>
      <div class="mt-1 text-xs leading-relaxed text-text-body">${violation.message ?? 'Coordination invariant needs attention.'}</div>
      <div class="mt-1 truncate text-3xs text-text-dim" title=${refsLabel(violation.refs)}>${refsLabel(violation.refs)}</div>
      ${evidence.length > 0 ? html`
        <ul class="mt-2 grid gap-1">
          ${evidence.map((item, index) => html`
            <${CoordinationEvidenceRow} key=${`${item.source ?? 'evidence'}-${item.kind ?? 'kind'}-${item.id ?? index}`} evidence=${item} />
          `)}
        </ul>
      ` : null}
    </li>
  `
}

function CoordinationHealthPanel() {
  const snapshot = coordinationFsmSnapshot.value
  if (!snapshot) return null
  const violations = snapshot.violations ?? []
  const topViolations = violations.slice(0, 5)
  const topEvidence = (snapshot.evidence ?? []).slice(0, 5)
  const errorCount = coordinationCount(snapshot, 'error')
  const warnCount = coordinationCount(snapshot, 'warn')
  const evidenceCount = coordinationCount(snapshot, 'evidence')
  return html`
    <section class="rounded border border-card-border/70 bg-[rgba(8,13,22,0.74)] p-3" aria-label="Coordination Health">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div class="text-sm font-semibold text-text-strong">Coordination Health</div>
          <div class="text-2xs text-text-dim">Goal x Task x Board x Reward · ${snapshot.mode ?? 'advisory'}</div>
        </div>
        <div class="flex flex-wrap items-center gap-2 text-3xs font-medium">
          <span class="rounded border border-card-border/60 bg-white/4 px-2 py-1 text-text-body">
            products ${coordinationCount(snapshot, 'products')}
          </span>
          <span class="rounded border border-card-border/60 bg-white/4 px-2 py-1 text-text-body">
            violations ${coordinationCount(snapshot, 'violations')}
          </span>
          <span class="rounded border border-card-border/60 bg-white/4 px-2 py-1 text-text-body">
            evidence ${evidenceCount}
          </span>
          ${errorCount > 0 ? html`
            <span class="rounded border border-bad/35 bg-bad/10 px-2 py-1 text-bad">error ${errorCount}</span>
          ` : null}
          ${warnCount > 0 ? html`
            <span class="rounded border border-warn/35 bg-warn/10 px-2 py-1 text-warn">warn ${warnCount}</span>
          ` : null}
        </div>
      </div>
      ${snapshot.projection_error ? html`
        <div class="mt-2 rounded border border-warn/30 bg-warn/10 px-2 py-1 text-xs text-warn" role="alert">
          projection: ${snapshot.projection_error}
        </div>
      ` : null}
      ${violations.length === 0 ? html`
        <div class="mt-2 text-xs text-text-muted">Aligned</div>
      ` : html`
        <ul class="mt-2 grid gap-2">
          ${topViolations.map((violation, index) => html`
            <${CoordinationViolationRow} key=${`${violation.code ?? violation.axis ?? 'coordination'}-${index}`} violation=${violation} />
          `)}
        </ul>
      `}
      ${topEvidence.length > 0 ? html`
        <div class="mt-3">
          <div class="mb-1 text-3xs font-semibold uppercase text-text-muted">Evidence</div>
          <ul class="grid gap-1 md:grid-cols-2">
            ${topEvidence.map((item, index) => html`
              <${CoordinationEvidenceRow} key=${`${item.source ?? 'evidence'}-${item.kind ?? 'kind'}-${item.id ?? index}`} evidence=${item} />
            `)}
          </ul>
        </div>
      ` : null}
    </section>
  `
}

export function PlanningPanel() {
  const view = activeView.value

  return html`
    <div class="flex flex-col gap-4" role="region" aria-label="기획 패널">
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="sm"
        tone="accent"
      />
      <${CoordinationHealthPanel} />
      ${view === 'goal-tree'
        ? html`<${GoalTree} />`
        : html`<${Planning} />`}
    </div>
  `
}
