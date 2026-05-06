import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { navigate, replaceRoute, route } from '../router'
import { goals, tasks } from '../store'
import type { Goal, Task } from '../types'
import { FilterChips } from './common/filter-chips'
import { deriveStaleTaskEntries, STALE_THRESHOLD_SECONDS, type StaleEntry } from './goals/task-stale-alert'

type PlanningFocus = 'none' | 'stale' | 'accountability-ledger' | 'accountability-matrix'
type TaskStatusBucket = 'todo' | 'claimed' | 'in_progress' | 'awaiting_verification' | 'done' | 'other'

interface AccountabilityTask {
  task: Task
  status: TaskStatusBucket
  stale: boolean
  goalTitle: string | null
}

interface AccountabilityRow {
  principal: string
  total: number
  active: number
  stale: number
  counts: Record<TaskStatusBucket, number>
  tasks: AccountabilityTask[]
}

const FOCUS_CHIPS: Array<{ key: PlanningFocus; label: string; title?: string }> = [
  { key: 'none', label: '전체' },
  { key: 'stale', label: '점유 지연', title: 'claimed/in_progress 태스크 중 오래 갱신되지 않은 항목' },
  { key: 'accountability-ledger', label: '책임 원장', title: 'assignee별 활성 태스크와 정체 신호' },
  { key: 'accountability-matrix', label: '책임 매트릭스', title: 'assignee x 태스크 상태 분포' },
]

const STATUS_BUCKETS: TaskStatusBucket[] = ['todo', 'claimed', 'in_progress', 'awaiting_verification', 'done', 'other']

const STATUS_LABELS: Record<TaskStatusBucket, string> = {
  todo: 'todo',
  claimed: 'claimed',
  in_progress: 'progress',
  awaiting_verification: 'verify',
  done: 'done',
  other: 'other',
}

function isPlanningFocus(v: string | undefined): v is Exclude<PlanningFocus, 'none'> {
  return v === 'stale' || v === 'accountability-ledger' || v === 'accountability-matrix'
}

const activeFocus = computed<PlanningFocus>(() => {
  const focus = route.value.params.focus
  return isPlanningFocus(focus) ? focus : 'none'
})

function updateFocusParam(focus: PlanningFocus): void {
  const params: Record<string, string> = { ...route.value.params, section: 'planning' }
  if (focus === 'none') {
    delete params.focus
    replaceRoute('workspace', params)
    return
  }

  params.focus = focus
  if (focus === 'stale') params.view = 'default'
  replaceRoute('workspace', params)
}

function statusBucket(status: Task['status']): TaskStatusBucket {
  if (status === 'todo' || status === 'claimed' || status === 'in_progress' || status === 'awaiting_verification' || status === 'done') {
    return status
  }
  return 'other'
}

function isActiveStatusBucket(status: TaskStatusBucket): boolean {
  return status === 'todo' || status === 'claimed' || status === 'in_progress' || status === 'awaiting_verification'
}

function taskTimeMs(task: Task): number {
  const ref = task.updated_at ?? task.created_at
  if (!ref) return 0
  const parsed = Date.parse(ref)
  return Number.isNaN(parsed) ? 0 : parsed
}

function principalForTask(task: Task): string {
  const assignee = task.assignee?.trim()
  return assignee && assignee.length > 0 ? assignee : 'unassigned'
}

function buildGoalTitleLookup(goalList: Goal[]): Map<string, string> {
  const lookup = new Map<string, string>()
  for (const goal of goalList) lookup.set(goal.id, goal.title)
  return lookup
}

function deriveAccountabilityRows(
  taskList: Task[],
  goalList: Goal[],
  staleEntries: StaleEntry[],
): AccountabilityRow[] {
  const staleIds = new Set(staleEntries.map(entry => entry.task.id))
  const goalTitles = buildGoalTitleLookup(goalList)
  const rows = new Map<string, AccountabilityRow>()

  for (const task of taskList) {
    const principal = principalForTask(task)
    const bucket = statusBucket(task.status)
    const row = rows.get(principal) ?? {
      principal,
      total: 0,
      active: 0,
      stale: 0,
      counts: { todo: 0, claimed: 0, in_progress: 0, awaiting_verification: 0, done: 0, other: 0 },
      tasks: [],
    }
    const stale = staleIds.has(task.id)
    row.total += 1
    row.counts[bucket] += 1
    if (isActiveStatusBucket(bucket)) row.active += 1
    if (stale) row.stale += 1
    row.tasks.push({
      task,
      status: bucket,
      stale,
      goalTitle: task.goal_id ? goalTitles.get(task.goal_id) ?? null : null,
    })
    rows.set(principal, row)
  }

  return [...rows.values()]
    .map(row => ({
      ...row,
      tasks: row.tasks.sort((a, b) => taskTimeMs(b.task) - taskTimeMs(a.task)),
    }))
    .sort((a, b) => b.stale - a.stale || b.active - a.active || b.total - a.total || a.principal.localeCompare(b.principal))
}

const staleEntriesForPlanning = computed<StaleEntry[]>(() => deriveStaleTaskEntries(tasks.value))
const accountabilityRowsForPlanning = computed<AccountabilityRow[]>(() =>
  deriveAccountabilityRows(tasks.value, goals.value, staleEntriesForPlanning.value),
)

function statusToneClass(status: TaskStatusBucket): string {
  switch (status) {
    case 'claimed':
    case 'in_progress':
      return 'border-warn/30 bg-warn/10 text-warn'
    case 'awaiting_verification':
      return 'border-[var(--accent-30)] bg-[var(--accent-10)] text-accent-fg'
    case 'done':
      return 'border-ok/30 bg-ok/10 text-ok'
    default:
      return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-muted'
  }
}

function shortTaskId(id: string): string {
  return id.length > 12 ? id.slice(0, 12) : id
}

function FocusFrame({
  title,
  meta,
  count,
  children,
}: {
  title: string
  meta: string
  count: string | number
  children: unknown
}) {
  return html`
    <section class="rounded-[var(--r-1)] border border-card-border/70 bg-[var(--color-bg-surface)] p-3" aria-label=${title}>
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div class="font-mono text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">planning focus</div>
          <h3 class="mt-1 text-sm font-semibold text-text-strong">${title}</h3>
          <p class="mt-1 text-xs leading-relaxed text-text-muted">${meta}</p>
        </div>
        <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-1 font-mono text-3xs text-text-body">
          ${count}
        </span>
      </header>
      <div class="mt-3">${children}</div>
    </section>
  `
}

function EmptyFocus({ message }: { message: string }) {
  return html`
    <div class="rounded-[var(--r-1)] border border-card-border/50 bg-black/10 px-3 py-4 text-xs text-text-muted">
      ${message}
    </div>
  `
}

function StaleFocus({ entries }: { entries: StaleEntry[] }) {
  return html`
    <${FocusFrame}
      title="오래된 태스크 점유"
      meta=${`claimed/in_progress 상태에서 ${Math.floor(STALE_THRESHOLD_SECONDS / 60)}분 이상 갱신되지 않은 항목입니다.`}
      count=${`${entries.length} stale`}
    >
      ${entries.length === 0 ? html`
        <${EmptyFocus} message="현재 오래 점유된 태스크가 없습니다." />
      ` : html`
        <ul class="grid gap-2" data-testid="planning-focus-stale">
          ${entries.slice(0, 8).map(entry => html`
            <li key=${entry.task.id} class="grid gap-2 rounded-[var(--r-1)] border border-warn/25 bg-warn/5 px-3 py-2 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
              <div class="min-w-0">
                <button
                  type="button"
                  class="font-mono text-2xs text-text-strong hover:underline"
                  title=${entry.task.id}
                  onClick=${() => navigate('workspace', { section: 'planning', view: 'default', task: entry.task.id, focus: 'stale' })}
                >
                  ${shortTaskId(entry.task.id)}
                </button>
                <div class="mt-1 truncate text-sm font-medium text-text-strong">${entry.task.title}</div>
                <div class="mt-1 flex flex-wrap gap-1.5 text-3xs text-text-muted">
                  ${entry.task.assignee ? html`<span>@${entry.task.assignee}</span>` : html`<span>unassigned</span>`}
                  ${entry.task.goal_id ? html`<span>goal ${entry.task.goal_id}</span>` : null}
                </div>
              </div>
              <div class="flex flex-wrap items-center gap-1.5 md:justify-end">
                <span class="rounded-[var(--r-1)] border border-warn/40 bg-warn/10 px-2 py-1 font-mono text-3xs text-warn">${entry.label}</span>
                ${entry.task.assignee ? html`
                  <button
                    type="button"
                    class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-1 font-mono text-3xs text-accent-fg hover:bg-[var(--accent-15)]"
                    onClick=${() => entry.task.assignee && navigate('monitoring', { section: 'agents', view: 'keepers', keeper: entry.task.assignee })}
                  >
                    nudge
                  </button>
                ` : null}
              </div>
            </li>
          `)}
        </ul>
      `}
    <//>
  `
}

function LedgerFocus({ rows }: { rows: AccountabilityRow[] }) {
  const activeRows = rows.filter(row => row.active > 0 || row.stale > 0)
  return html`
    <${FocusFrame}
      title="책임 원장"
      meta="assignee별 활성 태스크, 검증 대기, 오래된 점유를 한 줄에서 확인합니다."
      count=${`${rows.length} principals`}
    >
      ${rows.length === 0 ? html`
        <${EmptyFocus} message="아직 책임자에 연결된 태스크가 없습니다." />
      ` : html`
        <ul class="grid gap-2" data-testid="planning-focus-ledger">
          ${(activeRows.length > 0 ? activeRows : rows).slice(0, 8).map(row => html`
            <li key=${row.principal} class="rounded-[var(--r-1)] border border-card-border/60 bg-black/10 p-3">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  ${row.principal === 'unassigned' ? html`
                    <span class="font-mono text-xs font-semibold text-text-muted">${row.principal}</span>
                  ` : html`
                    <button
                      type="button"
                      class="font-mono text-xs font-semibold text-text-strong hover:underline"
                      onClick=${() => navigate('monitoring', { section: 'agents', view: 'keepers', keeper: row.principal })}
                    >
                      ${row.principal}
                    </button>
                  `}
                  <div class="mt-1 text-3xs text-text-muted">
                    active ${row.active} · total ${row.total}${row.stale > 0 ? ` · stale ${row.stale}` : ''}
                  </div>
                </div>
                <div class="flex flex-wrap gap-1">
                  ${STATUS_BUCKETS.map(status => row.counts[status] > 0 ? html`
                    <span key=${status} class="rounded-[var(--r-1)] border px-2 py-1 font-mono text-3xs ${statusToneClass(status)}">
                      ${STATUS_LABELS[status]} ${row.counts[status]}
                    </span>
                  ` : null)}
                </div>
              </div>
              <div class="mt-3 grid gap-1.5">
                ${row.tasks.slice(0, 3).map(item => html`
                  <button
                    key=${item.task.id}
                    type="button"
                    class="grid min-w-0 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 rounded-[var(--r-1)] border border-card-border/40 bg-[var(--color-bg-elevated)] px-2 py-1.5 text-left hover:border-card-border/80"
                    onClick=${() => navigate('workspace', { section: 'planning', view: 'default', task: item.task.id })}
                  >
                    <span class="font-mono text-3xs text-text-muted">${shortTaskId(item.task.id)}</span>
                    <span class="min-w-0 truncate text-xs text-text-body">${item.task.title}</span>
                    <span class="rounded-[var(--r-1)] border px-1.5 py-0.5 font-mono text-3xs ${item.stale ? 'border-warn/40 bg-warn/10 text-warn' : statusToneClass(item.status)}">
                      ${item.stale ? 'stale' : STATUS_LABELS[item.status]}
                    </span>
                  </button>
                `)}
              </div>
            </li>
          `)}
        </ul>
      `}
    <//>
  `
}

function MatrixCell({ value, tone }: { value: number; tone: TaskStatusBucket }) {
  return html`
    <td class="border-t border-card-border/50 px-2 py-2 text-right font-mono text-2xs tabular-nums ${value > 0 ? statusToneClass(tone) : 'text-text-dim'}">
      ${value}
    </td>
  `
}

function MatrixFocus({ rows }: { rows: AccountabilityRow[] }) {
  return html`
    <${FocusFrame}
      title="책임 매트릭스"
      meta="assignee x 상태 분포로 병목 구간과 검증 대기 집중도를 비교합니다."
      count=${`${rows.length} rows`}
    >
      ${rows.length === 0 ? html`
        <${EmptyFocus} message="매트릭스로 표시할 태스크가 없습니다." />
      ` : html`
        <div class="overflow-x-auto" data-testid="planning-focus-matrix">
          <table class="w-full min-w-[37.5rem] border-separate border-spacing-0 text-xs" aria-label="책임 매트릭스">
            <thead>
              <tr class="text-left font-mono text-3xs uppercase tracking-[var(--track-caps)] text-text-muted">
                <th class="px-2 py-2">assignee</th>
                ${STATUS_BUCKETS.map(status => html`<th key=${status} class="px-2 py-2 text-right">${STATUS_LABELS[status]}</th>`)}
                <th class="px-2 py-2 text-right">stale</th>
                <th class="px-2 py-2 text-right">active</th>
              </tr>
            </thead>
            <tbody>
              ${rows.slice(0, 12).map(row => html`
                <tr key=${row.principal}>
                  <th class="border-t border-card-border/50 px-2 py-2 text-left font-mono text-2xs text-text-strong">${row.principal}</th>
                  ${STATUS_BUCKETS.map(status => html`<${MatrixCell} key=${status} value=${row.counts[status]} tone=${status} />`)}
                  <td class="border-t border-card-border/50 px-2 py-2 text-right font-mono text-2xs tabular-nums ${row.stale > 0 ? 'text-warn' : 'text-text-dim'}">${row.stale}</td>
                  <td class="border-t border-card-border/50 px-2 py-2 text-right font-mono text-2xs tabular-nums text-text-body">${row.active}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      `}
    <//>
  `
}

export function PlanningFocusPanel() {
  const focus = activeFocus.value
  const staleEntries = staleEntriesForPlanning.value
  const rows = accountabilityRowsForPlanning.value
  const chips = FOCUS_CHIPS.map(chip => ({
    ...chip,
    count: chip.key === 'stale'
      ? staleEntries.length
      : chip.key === 'accountability-ledger' || chip.key === 'accountability-matrix'
        ? rows.length
        : null,
  }))

  return html`
    <div class="flex flex-col gap-3" aria-label="계획 포커스">
      <${FilterChips}
        chips=${chips}
        value=${focus}
        onChange=${updateFocusParam}
        size="sm"
        tone="accent"
      />
      ${focus === 'stale' ? html`<${StaleFocus} entries=${staleEntries} />` : null}
      ${focus === 'accountability-ledger' ? html`<${LedgerFocus} rows=${rows} />` : null}
      ${focus === 'accountability-matrix' ? html`<${MatrixFocus} rows=${rows} />` : null}
    </div>
  `
}
