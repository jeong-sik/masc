// Harness health reusable section sub-components.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { formatTimeAgo, formatTimestampKo } from '../lib/format-time'
import { assertExhaustive } from '../lib/exhaustive'
import { SurfaceCard } from './common/card'
import { TextInput } from './common/input'
import { SectionCap } from './common/section-cap'
import { StatusChip } from './common/status-chip'
import { StatusDot } from './common/status-dot'
import type {
  RailStatus,
  GateDistribution,
  HarnessHealthData,
  HarnessVerdictItem,
} from './harness-health-state'
import { verdictSummaryText, verdictToneClass, railStatusMessage } from '../lib/keeper-classifiers'

function ItemTitle({ children, class: cx }: { children: unknown; class?: string }) {
  return html`<div class=${`text-sm font-medium text-[var(--color-fg-secondary)] ${cx ?? ''}`}>${children}</div>
  `
}

/**
 * Pure filter for recent verdict rows.
 *
 * Case-insensitive substring match on `task_title`, `task_id`, `agent_name`,
 * `gate`, `evaluator_runtime`, and `verdict` so operators can locate a
 * verdict by any visible identifier.
 *
 * Empty/whitespace query returns the input reference unchanged so
 * `useMemo` keeps referential equality for the non-filtering path.
 *
 * Input is never mutated.
 */
export function filterVerdicts(
  items: readonly HarnessVerdictItem[],
  query: string,
): readonly HarnessVerdictItem[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return items
  return items.filter(item => {
    if (item.task_title && item.task_title.toLowerCase().includes(needle)) return true
    if (item.task_id && item.task_id.toLowerCase().includes(needle)) return true
    if (item.agent_name && item.agent_name.toLowerCase().includes(needle)) return true
    if (item.gate && item.gate.toLowerCase().includes(needle)) return true
    if (item.evaluator_runtime && item.evaluator_runtime.toLowerCase().includes(needle)) return true
    if (item.verdict && item.verdict.toLowerCase().includes(needle)) return true
    return false
  })
}

// ── Helper functions ──

// RailStatus consumers below intentionally retain `case 'idle': default:`
// pattern. Reason: data.overview.evaluator_status etc. arrive via
// `get<HarnessHealthData>('/api/v1/dashboard/harness-health')` — a type
// assertion, not a typed parse — so wire drift (older OCaml backend
// emitting a novel status) reaches these helpers with a value the type
// system promised wouldn't occur. The defensive default is load-bearing
// for prod render safety. Fixing properly requires a boundary parser
// (`membershipParse<RailStatus>` at load site) so a future RFC can flip
// these to `assertExhaustive`. Existing tests at lines 92, 118, 296 lock
// this contract via `'unknown' as any`.
export function railStatusLabel(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return '정상'
    case 'warning':
      return '주의'
    case 'stale':
      return '오래됨'
    case 'idle':
    default:
      return '대기'
  }
}

export function statusChipClass(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--color-status-ok)]'
    case 'warning':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--color-status-warn)]'
    case 'stale':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
    case 'idle':
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)]'
  }
}

export function statusCardClass(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)]'
    case 'warning':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)]'
    case 'stale':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'
    case 'idle':
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'
  }
}

export function freshnessLabel(ts: number | null | undefined, fallback = '기록 없음'): string {
  if (ts == null) return fallback
  return formatTimeAgo(ts)
}

export function verdictTone(verdict: string): string {
  return verdictToneClass(verdict)
}

export function verdictSummary(verdict: string): string {
  return verdictSummaryText(verdict)
}

export function heroTitle(data: HarnessHealthData): string {
  const statuses = [data.overview.evaluator_status]
  const msg = railStatusMessage(statuses)
  if (msg) return msg
  if (statuses.every(status => status === 'idle')) return '아직 감시 기록 없음'
  return '감시 채널이 정상 작동 중입니다.'
}

export function heroBody(data: HarnessHealthData): string {
  if (data.overview.evaluator_status === 'warning') {
    const ratio = Math.round((data.overview.fallback_ratio ?? 0) * 100)
    return `평가 모델의 대체 처리 비중이 ${ratio}%라 판정을 그대로 신뢰하기 어렵습니다.`
  }
  if (data.overview.last_signal_at == null) {
    return '평가 판정이 정상인지 감시합니다.'
  }
  return `마지막 안전 신호는 ${freshnessLabel(data.overview.last_signal_at)}에 들어왔습니다.`
}

export function railDetail(data: HarnessHealthData, rail: 'evaluator'): string {
  switch (rail) {
    case 'evaluator':
      if (data.calibration.total_verdicts === 0) return '판정 기록 없음'
      return `판정 ${data.calibration.total_verdicts}건`
  }
  return assertExhaustive(rail, 'HarnessRail')
}

export function railFreshness(data: HarnessHealthData, rail: 'evaluator'): string {
  switch (rail) {
    case 'evaluator':
      return freshnessLabel(data.overview.evaluator_last_event_at, '기록 없음')
  }
  return assertExhaustive(rail, 'HarnessRail')
}

// ── Small components ──

export function StatusPill({ status }: { status: RailStatus }) {
  return html`
    <${StatusChip} tone=${statusChipClass(status)} class="font-semibold">${railStatusLabel(status)}<//>
  `
}

export function EmptySignal({ text }: { text: string }) {
  return html`
    <div class="v2-lab-card rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-sm text-[var(--color-fg-disabled)]">
      ${text}
    </div>
  `
}

export function GateChart({ distribution }: { distribution: GateDistribution }) {
  const entries = Object.entries(distribution).sort((a, b) => b[1] - a[1])
  const max = entries[0]?.[1] ?? 1
  if (entries.length === 0) {
    return html`<${EmptySignal} text="아직 verdict 기록이 없습니다." />`
  }
  return html`
    <div class="space-y-2">
      ${entries.map(([gate, count]) => html`
        <div class="v2-lab-row flex items-center gap-2">
          <span class="w-20 text-right font-mono text-xs text-[var(--color-fg-muted)]">${gate}</span>
          <div class="h-4 flex-1 overflow-hidden rounded-[var(--r-1)] bg-[var(--color-bg-hover)]">
            <div
              class="h-full rounded-[var(--r-1)] opacity-80 transition-[width]"
              style=${{ width: `${(count / max) * 100}%`, background: 'var(--color-accent-fg)' }}
            />
          </div>
          <span class="w-8 text-right text-xs text-[var(--color-fg-primary)]">${count}</span>
        </div>
      `)}
    </div>
  `
}

export function HeroRailCard({
  label,
  status,
  detail,
  freshness,
}: {
  label: string
  status: RailStatus
  detail: string
  freshness: string
}) {
  return html`
    <div class=${`v2-lab-card rounded-[var(--r-1)] border p-3 ${statusCardClass(status)}`}>
      <div class="flex items-start justify-between gap-3">
        <${ItemTitle}>${label}</${ItemTitle}>
        <${StatusPill} status=${status} />
      </div>
      <div class="mt-3 text-lg font-semibold text-[var(--color-fg-primary)]">${detail}</div>
      <div class="mt-1 text-xs text-[var(--color-fg-disabled)]">최근 신호 ${freshness}</div>
    </div>
  `
}

export function ScopePairing() {
  return html`
    <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <div class="flex items-center justify-between gap-3">
            <div>
              <${SectionCap}>실험 루프<//>
              <${ItemTitle} class="mt-1">하네스가 답하는 것</${ItemTitle}>
            </div>
          </div>
          <div class="text-sm leading-loose text-[var(--color-fg-primary)]">
            evaluator rail의 상태를 확인합니다.
          </div>
        </div>
      <//>

      <${SurfaceCard} variant="compact">
        <div class="flex flex-col gap-2">
          <${SectionCap}>안전 감시<//>
          <${ItemTitle}>하네스가 답하는 것</${ItemTitle}>
          <div class="text-sm leading-loose text-[var(--color-fg-primary)]">
            평가 모델이 건강한지 봅니다.
          </div>
        </div>
      <//>
    </div>
  `
}

export function RailHeader({
  title,
  description,
  status,
  lastEventAt,
}: {
  title: string
  description: string
  status: RailStatus
  lastEventAt: number | null
}) {
  return html`
    <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
      <div>
        <div class="flex items-center gap-2">
          <${ItemTitle}>${title}</${ItemTitle}>
          <${StatusPill} status=${status} />
        </div>
        <div class="mt-1 text-sm leading-loose text-[var(--color-fg-muted)]">${description}</div>
      </div>
      <div class="text-xs text-[var(--color-fg-disabled)]">최근 신호 ${freshnessLabel(lastEventAt)}</div>
    </div>
  `
}

/** task id → the goal it serves, read off the goal tree already on this page.
 *
 * The tree carries each goal's tasks and the metric it is measured by, so the
 * map is the same links read the other way rather than a second fetch. Walks
 * children too: a task hangs off whichever node owns it, at any depth.
 *
 * A task under two goals keeps the first the walk meets. The alternative is a
 * card that lists several aims, which is a different screen than this one.
 */
export function goalsByTaskFromTree(
  nodes: readonly {
    id: string
    title: string
    metric?: string | null
    target_value?: string | null
    tasks?: readonly { id: string }[]
    children?: readonly unknown[]
  }[] | null | undefined,
): Map<string, { title: string; metric?: string | null; target_value?: string | null }> {
  const byTask = new Map<string, { title: string; metric?: string | null; target_value?: string | null }>()
  const walk = (list: readonly unknown[] | null | undefined): void => {
    for (const raw of list ?? []) {
      const node = raw as {
        title?: string
        metric?: string | null
        target_value?: string | null
        tasks?: readonly { id: string }[]
        children?: readonly unknown[]
      }
      for (const task of node.tasks ?? []) {
        if (task?.id && !byTask.has(task.id)) {
          byTask.set(task.id, {
            title: node.title ?? '(제목 없는 goal)',
            metric: node.metric ?? null,
            target_value: node.target_value ?? null,
          })
        }
      }
      walk(node.children)
    }
  }
  walk(nodes)
  return byTask
}

/** What a judged task is working towards, in one line.
 *
 * A verdict names a task, a task is linked to goals, and a goal declares the
 * metric it is measured by. All three were already on this page and none of
 * them met: a verdict read "approve" without saying what it was approving
 * towards.
 *
 * Returns null when the chain has nothing to say, so the caller draws nothing
 * rather than an empty label. A goal with no declared metric still answers —
 * its title is what the task is for, metric or not.
 */
export function verdictAim(
  taskId: string | null | undefined,
  goalsByTask: ReadonlyMap<string, { title: string; metric?: string | null; target_value?: string | null }>,
): string | null {
  if (!taskId) return null
  const goal = goalsByTask.get(taskId)
  if (!goal) return null
  const aim = goal.metric
    ? (goal.target_value ? `${goal.metric} → ${goal.target_value}` : goal.metric)
    : (goal.target_value ? `목표 ${goal.target_value}` : null)
  return aim ? `${goal.title} · ${aim}` : goal.title
}

// ── Section components ──

export function RecentVerdictsList({
  items,
  goalsByTask,
}: {
  items: HarnessVerdictItem[]
  /** task id → the goal it serves. Empty when the goals have not loaded; the
   *  cards then say nothing about aim rather than claiming there is none. */
  goalsByTask?: ReadonlyMap<string, { title: string; metric?: string | null; target_value?: string | null }>
}) {
  const query = useSignal('')
  const visibleItems = useMemo(
    () => filterVerdicts(items, query.value),
    [items, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  if (items.length === 0) {
    return html`<${EmptySignal} text="최근 평가 판정이 없습니다." />`
  }

  return html`
    <div class="space-y-2">
      <div class="flex justify-end">
        <${TextInput}
          type="search"
          class="min-w-40 max-w-65 flex-1 !px-2 !py-1 !text-2xs"
          value=${query.value}
          placeholder="task / agent / gate / runtime 필터"
          ariaLabel="판정 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
        />
      </div>
      ${isFiltering && visibleItems.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${items.length} items)</div>`
        : visibleItems.map(item => html`
          <${SurfaceCard} variant="compact">
            <div class="flex items-start justify-between gap-3">
              <div>
                <${ItemTitle}>${item.task_title || item.task_id}</${ItemTitle}>
                <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
                  ${item.agent_name || '(unknown agent)'} · ${item.gate || '(unknown gate)'} · ${item.evaluator_runtime || '(unknown runtime)'} · ${formatTimestampKo(item.timestamp)}
                </div>
              </div>
              <${StatusDot} size="md" class=${verdictTone(item.verdict)} />
            </div>
            <div class="mt-2 text-sm text-[var(--color-fg-primary)]">${verdictSummary(item.verdict)}</div>
            ${(() => {
              const aim = verdictAim(item.task_id, goalsByTask ?? new Map())
              return aim
                ? html`<div class="mt-1 text-xs text-[var(--color-fg-muted)]">→ ${aim}</div>`
                : null
            })()}
            ${item.fallback_reason ? html`
              <div class="mt-2 break-all text-xs text-[var(--color-status-warn)]">${item.fallback_reason}</div>
            ` : null}
          <//>
        `)}
    </div>
  `
}

