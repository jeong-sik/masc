import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'
import { get } from '../api/core'
import { AsyncContainer } from './common/async-container'
import { Card } from './common/card'
import { StatCard } from './common/stat-card'
import { JsonViewerCard } from './common/json-viewer'
import { EmptyState } from './common/empty-state'
import { formatTimeAgo } from '../lib/format-time'
import {
  asBoolean,
  asNumber,
  asRecordArray,
  asString,
  asStringArray,
  isRecord,
} from './common/normalize'

type DomainStatus = 'pass' | 'warn' | 'fail'

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
}

const safeAutonomy: AsyncResource<SafeAutonomyData> = createAsyncResource()

function statusTone(status: DomainStatus): string {
  switch (status) {
    case 'pass':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--ok)]'
    case 'warn':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--warn)]'
    case 'fail':
    default:
      return 'border-[var(--bad-30)] bg-[var(--bad-12)] text-[var(--bad)]'
  }
}

function statusLabel(status: DomainStatus): string {
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

function normalizeSummary(value: unknown): ScorecardSummary {
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

function normalizeDomain(value: unknown): ScorecardItem {
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

function normalizeKeeper(value: unknown): KeeperItem {
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

function normalizeFinding(value: unknown): FindingItem {
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

function normalizeTimelineItem(value: unknown): TimelineItem {
  const item = isRecord(value) ? value : {}
  return {
    ts_iso: asString(item.ts_iso, ''),
    kind: asString(item.kind, 'event'),
    keeper_name: asString(item.keeper_name) ?? null,
    summary: asString(item.summary, ''),
  }
}

function normalizePayload(raw: unknown): SafeAutonomyData {
  const data = isRecord(raw) ? raw : {}
  return {
    generated_at: asString(data.generated_at, ''),
    summary: normalizeSummary(data.summary),
    domains: asRecordArray(data.domains).map(normalizeDomain),
    per_keeper: asRecordArray(data.per_keeper).map(normalizeKeeper),
    findings: asRecordArray(data.findings).map(normalizeFinding),
    timeline: asRecordArray(data.timeline).map(normalizeTimelineItem),
    artifacts: isRecord(data.artifacts) ? data.artifacts : {},
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
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <div class="text-sm font-semibold text-[var(--text-strong)]">${item.label}</div>
            <${StatusPill} status=${item.status} />
          </div>
          <div class="mt-1 text-xs text-[var(--text-muted)]">${item.summary}</div>
        </div>
        <div class="text-right">
          <div class="text-lg font-semibold text-[var(--text-strong)]">${item.score.toFixed(1)}</div>
          <div class="text-3xs uppercase tracking-wide text-[var(--text-muted)]">
            weight ${item.weight ?? 0}
          </div>
        </div>
      </div>
    </div>
  `
}

function KeeperCard({ item }: { item: KeeperItem }) {
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-4">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <div class="text-sm font-semibold text-[var(--text-strong)]">${item.name}</div>
            <${StatusPill} status=${item.status} />
          </div>
          <div class="mt-1 text-xs text-[var(--text-muted)]">
            ${item.agent_name} · ${item.sandbox_profile}/${item.sandbox_backend} · ${item.network_mode}
          </div>
          <div class="mt-2 text-sm text-[var(--text-body)]">${item.goal || 'goal 없음'}</div>
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-[var(--text-muted)]">
            ${item.active_goal_ids.map(goalId => html`
              <span class="rounded border border-[var(--white-10)] bg-[var(--white-6)] px-2 py-0.5">${goalId}</span>
            `)}
          </div>
          ${item.last_blocker
            ? html`
              <div class="mt-3 rounded border border-[var(--warn-30)] bg-[var(--warn-12)] px-3 py-2 text-xs text-[var(--warn)]" role="alert">
                blocker: ${item.last_blocker}
              </div>
            `
            : null}
        </div>
        <div class="grid grid-cols-2 gap-2 text-xs lg:min-w-[220px]">
          <${StatCard} label="score" value=${item.score.toFixed(1)} />
          <${StatCard} label="approvals" value=${item.approval_pending_count} />
          <${StatCard} label="turns" value=${item.total_turns} />
          <${StatCard} label="activity" value=${item.recent_activity_count} />
          <${StatCard} label="history" value=${item.trace_history_count} />
          <${StatCard} label="task" value=${item.current_task_id ?? 'none'} />
        </div>
      </div>
    </div>
  `
}

function FindingsList({ findings }: { findings: FindingItem[] }) {
  if (findings.length === 0) {
    return html`<${EmptyState} message="현재 기록된 세이프 오토노미 finding이 없습니다." compact />`
  }
  return html`
    <div class="space-y-2">
      ${findings.map(item => html`
        <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <code class="text-3xs text-[var(--text-muted)]">${item.reason_code}</code>
                <${StatusPill} status=${item.severity} />
                ${item.keeper_name ? html`<span class="text-3xs text-[var(--text-muted)]">${item.keeper_name}</span>` : null}
              </div>
              <div class="mt-1 text-sm text-[var(--text-strong)]">${item.summary}</div>
              <div class="mt-1 text-xs text-[var(--text-muted)]">${item.suggested_next_action}</div>
            </div>
            ${item.human_action_required
              ? html`
                <span class="rounded border border-[var(--bad-30)] bg-[var(--bad-12)] px-2 py-1 text-3xs font-semibold uppercase tracking-wide text-[var(--bad)]">
                  human
                </span>
              `
              : null}
          </div>
        </div>
      `)}
    </div>
  `
}

function TimelineList({ timeline }: { timeline: TimelineItem[] }) {
  if (timeline.length === 0) {
    return html`<${EmptyState} message="최근 타임라인 이벤트가 없습니다." compact />`
  }
  return html`
    <div class="space-y-2">
      ${timeline.map(item => html`
        <div class="rounded border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="text-xs text-[var(--text-strong)]">${item.summary}</div>
              <div class="mt-1 text-3xs text-[var(--text-muted)]">
                ${item.kind}${item.keeper_name ? ` · ${item.keeper_name}` : ''}
              </div>
            </div>
            <div class="shrink-0 text-3xs text-[var(--text-muted)]">
              ${item.ts_iso ? formatTimeAgo(item.ts_iso) : '정보 없음'}
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
    <div class="space-y-4" role="region" aria-label="세이프 오토노미">
      <${Card} title="Safe Autonomy" class="section">
        <${AsyncContainer}
          state=${safeAutonomy.state}
          loadingMessage="세이프 오토노미 scorecard를 불러오는 중..."
          render=${(data: SafeAutonomyData) => html`
            <div class="space-y-4">
              <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-4">
                <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div class="max-w-3xl">
                    <div class="text-2xs font-semibold uppercase tracking-1 text-[var(--text-muted)]">
                      Advisory Truth Layer
                    </div>
                    <div class="mt-2 flex items-center gap-2">
                      <div class="text-2xl font-semibold text-[var(--text-strong)]">
                        ${data.summary.global_score.toFixed(1)}
                      </div>
                      <${StatusPill} status=${data.summary.status} />
                    </div>
                    <div class="mt-2 text-sm leading-paragraph text-[var(--text-body)]">
                      Tool correctness, sandbox truth, approval gates, cascade/FSM gracefulness,
                      audit trail completeness를 keeper별로 한 번에 보여줍니다.
                    </div>
                    <div class="mt-2 text-3xs text-[var(--text-muted)]">
                      generated ${data.generated_at ? formatTimeAgo(data.generated_at) : '정보 없음'}
                    </div>
                  </div>
                  <div class="grid grid-cols-2 gap-2 xl:grid-cols-4">
                    <${StatCard} label="keepers" value=${data.summary.keeper_count} />
                    <${StatCard} label="active goals" value=${data.summary.active_goal_count} />
                    <${StatCard} label="findings" value=${data.summary.findings_total} />
                    <${StatCard} label="human queue" value=${data.summary.human_action_required_count} />
                    <${StatCard} label="with task" value=${data.summary.keepers_with_current_task} />
                    <${StatCard} label="approval depth" value=${data.summary.approval_queue_depth} />
                  </div>
                </div>
              </div>

              <div class="grid grid-cols-1 gap-3 xl:grid-cols-2">
                ${data.domains.map(item => html`<${DomainCard} key=${item.id} item=${item} />`)}
              </div>

              <${Card} title="Keeper Matrix" class="section">
                <div class="space-y-3">
                  ${data.per_keeper.length === 0
                    ? html`<${EmptyState} message="표시할 keeper snapshot이 없습니다." compact />`
                    : data.per_keeper.map(item => html`<${KeeperCard} key=${item.name} item=${item} />`)}
                </div>
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
