import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'
import { get } from '../api/core'
import { AsyncContainer } from './common/async-container'
import { Card } from './common/card'
import { JsonViewerCard } from './common/json-viewer'
import { EmptyState } from './common/empty-state'
import { InfoCard } from './common/info-card'
import { KeeperBadge } from './keeper-badge'
import { KpiStripIsland, type KpiStripIslandData } from './kpi-strip-island'
import { formatTimeAgoEn } from '../lib/format-time'
import {
  asBoolean,
  asNumber,
  asRecordArray,
  asString,
  asStringArray,
  isRecord,
} from './common/normalize'

export type DomainStatus = 'pass' | 'warn' | 'fail'

interface ScorecardSummary {
  global_score: number
  status: DomainStatus
  keeper_count: number
  active_goal_count: number
  keepers_with_current_task: number
  findings_total: number
  human_action_required_count: number
  approval_queue_depth: number
}

interface ScorecardItem {
  id: string
  label: string
  status: DomainStatus
  score: number
  summary: string
  weight?: number
  evidence_refs?: unknown[]
}

interface KeeperItem {
  name: string
  agent_name: string
  status: DomainStatus
  score: number
  sandbox_profile: string
  sandbox_backend: string
  network_mode: string
  approval_pending_count: number
  trace_history_count: number
  recent_activity_count: number
  total_turns: number
  goal: string
  active_goal_ids: string[]
  current_task_id: string | null
  last_blocker: string | null
}

interface FindingItem {
  reason_code: string
  domain_id: string
  severity: DomainStatus
  keeper_name: string | null
  summary: string
  human_action_required: boolean
  suggested_next_action: string
}

interface TimelineItem {
  ts_iso: string
  kind: string
  keeper_name: string | null
  summary: string
}

interface SafeAutonomyData {
  generated_at: string
  summary: ScorecardSummary
  domains: ScorecardItem[]
  per_keeper: KeeperItem[]
  findings: FindingItem[]
  timeline: TimelineItem[]
  artifacts: Record<string, unknown>
  history: number[]
}

const safeAutonomy: AsyncResource<SafeAutonomyData> = createAsyncResource()

export function statusTone(status: DomainStatus): string {
  switch (status) {
    case 'pass':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--color-status-ok)]'
    case 'warn':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--color-status-warn)]'
    case 'fail':
    default:
      return 'border-[var(--bad-30)] bg-[var(--bad-12)] text-[var(--color-status-err)]'
  }
}

export function statusLabel(status: DomainStatus): string {
  switch (status) {
    case 'pass':
      return 'PASS'
    case 'warn':
      return 'WARN'
    case 'fail':
    default:
      return 'FAIL'
  }
}

export function normalizeSummary(value: unknown): ScorecardSummary {
  const summary = isRecord(value) ? value : {}
  return {
    global_score: asNumber(summary.global_score, 0),
    status: (asString(summary.status, 'warn') as DomainStatus),
    keeper_count: asNumber(summary.keeper_count, 0),
    active_goal_count: asNumber(summary.active_goal_count, 0),
    keepers_with_current_task: asNumber(summary.keepers_with_current_task, 0),
    findings_total: asNumber(summary.findings_total, 0),
    human_action_required_count: asNumber(summary.human_action_required_count, 0),
    approval_queue_depth: asNumber(summary.approval_queue_depth, 0),
  }
}

export function normalizeDomain(value: unknown): ScorecardItem {
  const item = isRecord(value) ? value : {}
  return {
    id: asString(item.id, 'domain'),
    label: asString(item.label, 'Domain'),
    status: (asString(item.status, 'warn') as DomainStatus),
    score: asNumber(item.score, 0),
    summary: asString(item.summary, ''),
    weight: asNumber(item.weight),
    evidence_refs: Array.isArray(item.evidence_refs) ? item.evidence_refs : [],
  }
}

export function normalizeKeeper(value: unknown): KeeperItem {
  const item = isRecord(value) ? value : {}
  return {
    name: asString(item.name, 'keeper'),
    agent_name: asString(item.agent_name, ''),
    status: (asString(item.status, 'warn') as DomainStatus),
    score: asNumber(item.score, 0),
    sandbox_profile: asString(item.sandbox_profile, 'unknown'),
    sandbox_backend: asString(item.sandbox_backend, 'unknown'),
    network_mode: asString(item.network_mode, 'unknown'),
    approval_pending_count: asNumber(item.approval_pending_count, 0),
    trace_history_count: asNumber(item.trace_history_count, 0),
    recent_activity_count: asNumber(item.recent_activity_count, 0),
    total_turns: asNumber(item.total_turns, 0),
    goal: asString(item.goal, ''),
    active_goal_ids: asStringArray(item.active_goal_ids),
    current_task_id: asString(item.current_task_id) ?? null,
    last_blocker: asString(item.last_blocker) ?? null,
  }
}

export function normalizeFinding(value: unknown): FindingItem {
  const item = isRecord(value) ? value : {}
  return {
    reason_code: asString(item.reason_code, 'unknown'),
    domain_id: asString(item.domain_id, 'unknown'),
    severity: (asString(item.severity, 'warn') as DomainStatus),
    keeper_name: asString(item.keeper_name) ?? null,
    summary: asString(item.summary, ''),
    human_action_required: asBoolean(item.human_action_required, false),
    suggested_next_action: asString(item.suggested_next_action, ''),
  }
}

export function normalizeTimelineItem(value: unknown): TimelineItem {
  const item = isRecord(value) ? value : {}
  return {
    ts_iso: asString(item.ts_iso, ''),
    kind: asString(item.kind, 'event'),
    keeper_name: asString(item.keeper_name) ?? null,
    summary: asString(item.summary, ''),
  }
}

export function normalizePayload(raw: unknown): SafeAutonomyData {
  const data = isRecord(raw) ? raw : {}
  const historyRaw = Array.isArray(data.history) ? data.history : []
  const history = historyRaw
    .map((v) => (typeof v === 'number' ? v : undefined))
    .filter((v): v is number => v !== undefined)
  return {
    generated_at: asString(data.generated_at, ''),
    summary: normalizeSummary(data.summary),
    domains: asRecordArray(data.domains).map(normalizeDomain),
    per_keeper: asRecordArray(data.per_keeper).map(normalizeKeeper),
    findings: asRecordArray(data.findings).map(normalizeFinding),
    timeline: asRecordArray(data.timeline).map(normalizeTimelineItem),
    artifacts: isRecord(data.artifacts) ? data.artifacts : {},
    history,
  }
}

function loadSafeAutonomy(): Promise<void> {
  return safeAutonomy.load(async () =>
    normalizePayload(await get<unknown>('/api/v1/dashboard/safe-autonomy')))
}

function StatusPill({ status }: { status: DomainStatus }) {
  return html`
    <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 text-3xs font-semibold uppercase tracking-wide ${statusTone(status)}`}>
      ${statusLabel(status)}
    </span>
  `
}

function DomainCard({ item }: { item: ScorecardItem }) {
  return html`
    <${InfoCard}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <div class="text-sm font-semibold text-[var(--color-fg-secondary)]">${item.label}</div>
            <${StatusPill} status=${item.status} />
          </div>
          <div class="mt-1 text-xs text-[var(--color-fg-muted)]">${item.summary}</div>
        </div>
        <div class="text-right">
          <div class="text-lg font-semibold text-[var(--color-fg-secondary)]">${item.score.toFixed(1)}</div>
          <div class="text-3xs uppercase tracking-wide text-[var(--color-fg-muted)]">
            weight ${item.weight ?? 0}
          </div>
        </div>
      </div>
    <//>
  `
}

function KeeperCard({ item }: { item: KeeperItem }) {
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-4">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <${KeeperBadge} id=${item.name} variant="full" size="md" />
            <${StatusPill} status=${item.status} />
          </div>
          <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
            ${item.agent_name} · ${item.sandbox_profile}/${item.sandbox_backend} · ${item.network_mode}
          </div>
          <div class="mt-2 text-sm text-[var(--color-fg-primary)]">${item.goal || 'No goal'}</div>
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-muted)]">
            ${item.active_goal_ids.map(goalId => html`
              <span class="rounded border border-[var(--white-10)] bg-[var(--white-6)] px-2 py-0.5">${goalId}</span>
            `)}
          </div>
          ${item.last_blocker
            ? html`
              <div class="mt-3 rounded border border-[var(--warn-30)] bg-[var(--warn-12)] px-3 py-2 text-xs text-[var(--color-status-warn)]">
                blocker: ${item.last_blocker}
              </div>
            `
            : null}
        </div>
        <div class="text-xs lg:min-w-[220px]">
          <${KpiStripIsland}
            ariaLabel="Domain statistics"
            cols=${2}
            cells=${[
              { variant: 'stacked', label: 'score', value: item.score.toFixed(1) },
              { variant: 'stacked', label: 'approvals', value: item.approval_pending_count },
              { variant: 'stacked', label: 'turns', value: item.total_turns },
              { variant: 'stacked', label: 'activity', value: item.recent_activity_count },
              { variant: 'stacked', label: 'history', value: item.trace_history_count },
              { variant: 'stacked', label: 'task', value: item.current_task_id ?? 'none' },
            ] satisfies KpiStripIslandData['cells']}
          />
        </div>
      </div>
    </div>
  `
}

function FindingsList({ findings }: { findings: FindingItem[] }) {
  if (findings.length === 0) {
    return html`<${EmptyState} message="No safe-autonomy findings are recorded." compact />`
  }
  return html`
    <div class="space-y-2">
      ${findings.map(item => html`
        <${InfoCard}>
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <code class="text-3xs text-[var(--color-fg-muted)]">${item.reason_code}</code>
                <${StatusPill} status=${item.severity} />
                ${item.keeper_name ? html`<${KeeperBadge} id=${item.keeper_name} variant="full" size="sm" />` : null}
              </div>
              <div class="mt-1 text-sm text-[var(--color-fg-secondary)]">${item.summary}</div>
              <div class="mt-1 text-xs text-[var(--color-fg-muted)]">${item.suggested_next_action}</div>
            </div>
            ${item.human_action_required
              ? html`
                <span class="rounded border border-[var(--bad-30)] bg-[var(--bad-12)] px-2 py-1 text-3xs font-semibold uppercase tracking-wide text-[var(--color-status-err)]">
                  human
                </span>
              `
              : null}
          </div>
        <//>
      `)}
    </div>
  `
}

function SafeAutonomyTrend({ history }: { history: number[] }) {
  if (history.length === 0) {
    return html`<${EmptyState} message="Trend appears after enough history is collected." compact />`
  }
  const min = Math.min(...history)
  const max = Math.max(...history)
  const range = max - min || 1
  const threshold = 78
  return html`
    <div class="space-y-2">
      <div class="flex items-end gap-1 h-16">
        ${history.map((score) => {
          const pct = Math.max(0, Math.min(100, ((score - min) / range) * 100))
          const belowThreshold = score < threshold
          return html`
            <div
              class="flex-1 rounded-sm ${belowThreshold
                ? 'bg-[var(--bad-30)]'
                : 'bg-[var(--ok-30)]'}"
              style=${`height: ${pct}%`}
              title=${`score: ${score.toFixed(1)}`}
            />
          `
        })}
      </div>
      <div class="flex items-center justify-between text-3xs text-[var(--color-fg-muted)]">
        <span>min ${min.toFixed(1)}</span>
        <span class="font-semibold text-[var(--color-fg-secondary)]">current ${history[history.length - 1]!.toFixed(1)}</span>
        <span>max ${max.toFixed(1)}</span>
      </div>
    </div>
  `
}

function TimelineList({ timeline }: { timeline: TimelineItem[] }) {
  if (timeline.length === 0) {
    return html`<${EmptyState} message="No recent timeline events." compact />`
  }
  return html`
    <div class="space-y-2">
      ${timeline.map(item => html`
        <div class="rounded border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="text-xs text-[var(--color-fg-secondary)]">${item.summary}</div>
              <div class="mt-1 flex flex-wrap items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
                <span>${item.kind}</span>
                ${item.keeper_name ? html`
                  <span aria-hidden="true">·</span>
                  <${KeeperBadge} id=${item.keeper_name} variant="full" size="sm" />
                ` : null}
              </div>
            </div>
            <div class="shrink-0 text-3xs text-[var(--color-fg-muted)]">
              ${item.ts_iso ? formatTimeAgoEn(item.ts_iso) : 'unknown'}
            </div>
          </div>
        </div>
      `)}
    </div>
  `
}

export function SafeAutonomyPanel() {
  useEffect(() => {
    void loadSafeAutonomy()
  }, [])

  return html`
    <div class="space-y-4">
      <${Card} title="Safe Autonomy" class="section">
        <${AsyncContainer}
          state=${safeAutonomy.state}
          loadingMessage="Loading safe-autonomy scorecard..."
          render=${(data: SafeAutonomyData) => html`
            <div class="space-y-4">
              <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-4">
                <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div class="max-w-3xl">
                    <div class="text-2xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)]">
                      Advisory Truth Layer
                    </div>
                    <div class="mt-2 flex items-center gap-2">
                      <div class="text-2xl font-semibold text-[var(--color-fg-secondary)]">
                        ${data.summary.global_score.toFixed(1)}
                      </div>
                      <${StatusPill} status=${data.summary.status} />
                    </div>
                    <div class="mt-2 text-sm leading-paragraph text-[var(--color-fg-primary)]">
                      Shows tool correctness, sandbox truth, approval gates, cascade/FSM gracefulness,
                      and audit trail completeness per keeper.
                    </div>
                    <div class="mt-2 text-3xs text-[var(--color-fg-muted)]">
                      generated ${data.generated_at ? formatTimeAgoEn(data.generated_at) : 'unknown'}
                    </div>
                  </div>
                  <${KpiStripIsland}
                    ariaLabel="Safe-autonomy summary"
                    cols=${4}
                    cells=${[
                      { variant: 'stacked', label: 'keepers', value: data.summary.keeper_count },
                      { variant: 'stacked', label: 'active goals', value: data.summary.active_goal_count },
                      { variant: 'stacked', label: 'findings', value: data.summary.findings_total },
                      { variant: 'stacked', label: 'human queue', value: data.summary.human_action_required_count },
                      { variant: 'stacked', label: 'with task', value: data.summary.keepers_with_current_task },
                      { variant: 'stacked', label: 'approval depth', value: data.summary.approval_queue_depth },
                    ] satisfies KpiStripIslandData['cells']}
                  />
                </div>
              </div>

              <div class="grid grid-cols-1 gap-3 xl:grid-cols-2">
                ${data.domains.map(item => html`<${DomainCard} key=${item.id} item=${item} />`)}
              </div>

              <${Card} title="Keeper Matrix" class="section">
                <div class="space-y-3">
                  ${data.per_keeper.length === 0
                    ? html`<${EmptyState} message="No keeper snapshots to display." compact />`
                    : data.per_keeper.map(item => html`<${KeeperCard} key=${item.name} item=${item} />`)}
                </div>
              <//>

              <${Card} title="Global Score Trend" class="section">
                <${SafeAutonomyTrend} history=${data.history} />
              <//>

              <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
                <${Card} title="Findings" class="section">
                  <${FindingsList} findings=${data.findings} />
                <//>
                <${Card} title="Timeline" class="section">
                  <${TimelineList} timeline=${data.timeline} />
                <//>
              </div>

              <${JsonViewerCard} title="Artifacts" data=${data.artifacts} />
            </div>
          `}
        />
      <//>
    </div>
  `
}
