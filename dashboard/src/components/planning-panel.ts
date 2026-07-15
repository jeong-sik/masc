// Planning Panel — task backlog and workspace evidence.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { replaceRoute, route } from '../router'
import { workspaceFsmSnapshot, tasks } from '../store'
import { Planning } from './tasks/planning'
import { PlanningFocusPanel } from './planning-focus-panel'
import { openTaskDetail } from './tasks/task-detail-state'
import type {
  DashboardWorkspaceFsmEvidence,
  DashboardWorkspaceFsmRefs,
  DashboardWorkspaceFsmSnapshot,
  DashboardWorkspaceFsmViolation,
} from '../types'

function workspaceCount(
  snapshot: DashboardWorkspaceFsmSnapshot | null,
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
      return 'border-[var(--accent-25)] bg-[var(--accent-10)] text-accent-fg'
  }
}

function refsLabel(refs: DashboardWorkspaceFsmRefs | undefined): string {
  if (!refs) return 'refs: -'
  const parts: string[] = []
  if (refs.task_ids && refs.task_ids.length > 0) parts.push(`tasks: ${refs.task_ids.join(', ')}`)
  if (refs.post_ids && refs.post_ids.length > 0) parts.push(`posts: ${refs.post_ids.join(', ')}`)
  if (refs.agent_name) parts.push(`agent: ${refs.agent_name}`)
  return parts.length > 0 ? parts.join(' · ') : 'refs: -'
}

function evidenceLabel(evidence: DashboardWorkspaceFsmEvidence): string {
  const source = evidence.source ?? '(unknown source)'
  const kind = evidence.kind ? `/${evidence.kind}` : ''
  return `${source}${kind}`
}

function cleanRouteFocusId(value: string | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : null
}

function clearPlanningRouteFocus(): void {
  const params: Record<string, string> = { ...route.value.params, section: 'planning' }
  delete params.task
  replaceRoute('workspace', params)
}

function PlanningRouteFocusPanel() {
  const params = route.value.params as Record<string, string | undefined>
  const taskId = cleanRouteFocusId(params.task)
  const task = taskId ? tasks.value.find(item => item.id === taskId) ?? null : null

  useEffect(() => {
    if (task) openTaskDetail(task)
  }, [task])

  if (!taskId) return null

  return html`
    <section
      class="v2-workspace-panel rounded-[var(--r-1)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] px-3 py-2"
      data-testid="planning-route-focus"
      data-route-focused-task=${taskId ?? undefined}
      aria-label="Planning route focus"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="font-mono text-3xs font-semibold uppercase tracking-[var(--track-section)] text-[var(--color-accent-fg)]">
            ROUTE FOCUS
          </div>
          <div class="mt-1 flex min-w-0 flex-wrap items-center gap-2 text-xs text-text-body">
            ${taskId ? html`
              <span class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-[var(--color-accent-fg)]">
                TASK ${taskId}
              </span>
              <span class="min-w-0 truncate text-sm font-semibold text-text-strong">
                ${task?.title ?? 'task not loaded'}
              </span>
              ${task?.assignee ? html`<span class="font-mono text-3xs text-text-muted">@${task.assignee}</span>` : null}
            ` : null}
          </div>
        </div>
        <button
          type="button"
          class="v2-workspace-action rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-text-muted transition-colors hover:border-[var(--color-border-strong)] hover:text-text-strong"
          onClick=${clearPlanningRouteFocus}
        >
          CLEAR
        </button>
      </div>
    </section>
  `
}

function WorkspaceEvidenceRow({ evidence }: { evidence: DashboardWorkspaceFsmEvidence }) {
  return html`
    <li class="min-w-0 rounded-[var(--r-1)] border border-card-border/40 bg-white/[0.03] px-2 py-1">
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="rounded-[var(--r-1)] border border-card-border/50 bg-black/15 px-1.5 py-0.5 text-3xs font-semibold uppercase text-text-muted">
          ${evidenceLabel(evidence)}
        </span>
        <span class="min-w-0 truncate text-2xs font-medium text-text-strong">
          ${evidence.label ?? evidence.id ?? '(unlabeled evidence)'}
        </span>
      </div>
      ${evidence.detail ? html`
        <div class="mt-0.5 truncate text-3xs text-text-dim" title=${evidence.detail}>${evidence.detail}</div>
      ` : null}
    </li>
  `
}

function WorkspaceViolationRow({ violation }: { violation: DashboardWorkspaceFsmViolation }) {
  const evidence = (violation.evidence ?? []).slice(0, 3)
  return html`
    <li class="rounded-[var(--r-1)] border border-card-border/60 bg-black/10 p-2">
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase ${severityToneClass(violation.severity)}">
          ${violation.severity ?? '(unknown severity)'}
        </span>
        <span class="font-mono text-2xs text-text-strong">${violation.code ?? violation.axis ?? '(unknown violation)'}</span>
        ${violation.axis ? html`<span class="text-3xs text-text-dim">${violation.axis}</span>` : null}
      </div>
      <div class="mt-1 text-xs leading-relaxed text-text-body">${violation.message ?? 'workspace invariant 검토 필요.'}</div>
      <div class="mt-1 truncate text-3xs text-text-dim" title=${refsLabel(violation.refs)}>${refsLabel(violation.refs)}</div>
      ${evidence.length > 0 ? html`
        <ul class="mt-2 grid gap-1">
          ${evidence.map((item, index) => html`
            <${WorkspaceEvidenceRow} key=${`${item.source ?? 'evidence'}-${item.kind ?? 'kind'}-${item.id ?? index}`} evidence=${item} />
          `)}
        </ul>
      ` : null}
    </li>
  `
}

function WorkspaceHealthPanel() {
  const snapshot = workspaceFsmSnapshot.value
  if (!snapshot) return null
  const violations = snapshot.violations ?? []
  const topViolations = violations.slice(0, 5)
  const topEvidence = (snapshot.evidence ?? []).slice(0, 5)
  const errorCount = workspaceCount(snapshot, 'error')
  const warnCount = workspaceCount(snapshot, 'warn')
  const evidenceCount = workspaceCount(snapshot, 'evidence')
  return html`
    <section class="v2-workspace-panel rounded-[var(--r-1)] border border-card-border/70 bg-[var(--color-bg-surface)] p-3" aria-label="협력 상태">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div class="text-sm font-semibold text-text-strong">협력 상태</div>
        </div>
        <div class="flex flex-wrap items-center gap-2 text-3xs font-medium">
          <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-1 text-text-body">
            products ${workspaceCount(snapshot, 'products')}
          </span>
          <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-1 text-text-body">
            violations ${workspaceCount(snapshot, 'violations')}
          </span>
          <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-1 text-text-body">
            evidence ${evidenceCount}
          </span>
          ${errorCount > 0 ? html`
            <span class="rounded-[var(--r-1)] border border-bad/35 bg-bad/10 px-2 py-1 text-bad">error ${errorCount}</span>
          ` : null}
          ${warnCount > 0 ? html`
            <span class="rounded-[var(--r-1)] border border-warn/35 bg-warn/10 px-2 py-1 text-warn">warn ${warnCount}</span>
          ` : null}
        </div>
      </div>
      ${snapshot.projection_error ? html`
        <div class="mt-2 rounded-[var(--r-1)] border border-warn/30 bg-warn/10 px-2 py-1 text-xs text-warn">
          projection: ${snapshot.projection_error}
        </div>
      ` : null}
      ${violations.length === 0 ? html`
        <div class="mt-2 text-xs text-text-muted">위반 없음</div>
      ` : html`
        <ul class="mt-2 grid gap-2">
          ${topViolations.map((violation, index) => html`
            <${WorkspaceViolationRow} key=${`${violation.code ?? violation.axis ?? 'workspace'}-${index}`} violation=${violation} />
          `)}
        </ul>
      `}
      ${violations.length > 0 && topEvidence.length > 0 ? html`
        <div class="mt-3">
          <div class="mb-1 text-3xs font-semibold uppercase text-text-muted">근거</div>
          <ul class="grid gap-1 md:grid-cols-2">
            ${topEvidence.map((item, index) => html`
              <${WorkspaceEvidenceRow} key=${`${item.source ?? 'evidence'}-${item.kind ?? 'kind'}-${item.id ?? index}`} evidence=${item} />
            `)}
          </ul>
        </div>
      ` : null}
    </section>
  `
}

export function PlanningPanel() {
  return html`
    <div class="v2-workspace-surface flex flex-col gap-4">
      <${PlanningRouteFocusPanel} />
      <${WorkspaceHealthPanel} />
      <${PlanningFocusPanel} />
      <${Planning} />
    </div>
  `
}
