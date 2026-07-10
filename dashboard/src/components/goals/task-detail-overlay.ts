// Task detail overlay — opens when clicking a task title in the kanban board

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useRef } from 'preact/hooks'
import { Check, X, ArrowRight, Dot, UserPlus } from 'lucide-preact'
import { DialogOverlay } from '../common/dialog'
import { StatusBadge } from '../common/status-badge'
import { EmptyState } from '../common/feedback-state'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { RichContent } from '../common/rich-content'
import { TextInput } from '../common/input'
import { TimeAgo } from '../common/time-ago'
import { findKeeper } from '../../lib/keeper-utils'
import { selectedTask } from './task-detail-selection'
import { tasks } from '../../store'
import {
  closeTaskDetail,
  openTaskDetail,
  taskEvents,
  taskEventsLoading,
  taskEventsError,
  taskEventsSearchQuery,
  filterTaskEvents,
  goalRelationSearchQuery,
  filterGoalRelations,
  assigneeGoalIds,
  activeTab,
  switchToActivityTab,
  activityEvents,
  activityLoading,
  activityError,
  hasActivityTab,
  isKeeperAssignee,
  buildTaskLineage,
  type NormalizedTaskEvent,
  type TaskDetailTab,
} from './task-detail-state'
import { TaskActivityList } from './task-activity-list'
import { effectiveTaskPriority, goalById, priorityLabel } from './goal-helpers'
import type { Task, TaskGateEvaluation } from '../../types'

const CARD_BOX = 'v2-workspace-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-3'

function SectionTitle({ children }: { children: unknown }) {
  return html`<div class="text-2xs font-semibold uppercase tracking-3 text-text-muted mb-2">${children}</div>`
}

// -- Event timeline (inline, NormalizedTaskEvent shape) --------------

function eventBadge(label: string): { icon: VNode; color: string } {
  switch (label) {
    case 'claim':
    case 'claimed': return { icon: html`<${UserPlus} size=${14} />`, color: 'text-accent-fg' }
    case 'done':
    case 'completed': return { icon: html`<${Check} size=${14} />`, color: 'text-ok' }
    case 'cancel':
    case 'cancelled': return { icon: html`<${X} size=${14} />`, color: 'text-bad' }
    case 'submit_for_verification':
    case 'awaiting_verification': return { icon: html`<${ArrowRight} size=${14} />`, color: 'text-accent-fg' }
    case 'approve':
    case 'approved': return { icon: html`<${Check} size=${14} />`, color: 'text-ok' }
    case 'reject':
    case 'rejected': return { icon: html`<${X} size=${14} />`, color: 'text-warn' }
    case 'transition': return { icon: html`<${ArrowRight} size=${14} />`, color: 'text-warn' }
    default: return { icon: html`<${Dot} size=${14} />`, color: 'text-text-muted' }
  }
}

function TaskEventsSection() {
  const events = taskEvents.value
  const loading = taskEventsLoading.value
  const error = taskEventsError.value
  const query = taskEventsSearchQuery.value

  if (loading) return html`<${LoadingState}>이벤트 불러오는 중...<//>`
  if (error) return html`<${ErrorState} message=${error} />`
  if (events.length === 0) return html`<${EmptyState} message="기록된 이벤트가 없습니다" compact />`

  const visible = filterTaskEvents(events, query)
  const trimmed = query.trim()

  return html`
    <div class="v2-workspace-panel flex flex-col gap-2">
      <div class="flex flex-wrap items-center gap-2">
        <${TextInput}
          type="search"
          value=${query}
          placeholder="이벤트 검색 (label/agent/notes)"
          ariaLabel="이벤트 검색"
          onInput=${(e: Event) => { taskEventsSearchQuery.value = (e.target as HTMLInputElement).value }}
          class="min-w-45 flex-1 !py-1 !text-2xs"
        />
        <span class="text-3xs text-[var(--color-fg-muted)] tabular-nums">
          ${trimmed
            ? `${visible.length} / ${events.length}`
            : `${events.length}개`}
        </span>
      </div>
      ${visible.length === 0
        ? html`<${EmptyState} message="검색 조건에 맞는 이벤트가 없습니다" compact />`
        : html`
      <div class="flex flex-col gap-0.5">
        ${visible.map((evt: NormalizedTaskEvent, i: number) => {
        const { icon, color } = eventBadge(evt.label)
        const key = evt.ts ? `${evt.ts}-${i}` : `${evt.label}-${i}`
        return html`
          <div key=${key} class="v2-workspace-row flex items-start gap-3 py-2 px-3 rounded-[var(--r-1)] hover:bg-[var(--color-bg-surface)] transition-colors">
            <div class="size-7 shrink-0 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] flex items-center justify-center text-2xs font-mono font-bold ${color}">
              ${icon}
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-xs font-medium text-text-strong">${evt.label}</span>
                ${evt.agent ? html`<span class="text-3xs text-accent-fg">@${evt.agent}${evt.actorKind ? ` · ${evt.actorKind}` : ''}</span>` : null}
              </div>
              ${evt.notes ? html`<div class="mt-1 text-2xs text-text-muted"><${RichContent} text=${evt.notes} previewLimit=${1} /></div>` : null}
            </div>
            ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} class="text-3xs text-text-dim shrink-0" />` : null}
          </div>
        `
      })}
      </div>
        `}
    </div>
  `
}

// -- Activity lineage (ownership chain + lifecycle rail) --------------

// Compact clock label (HH:MM) for the narrow rail time column — the rail's
// fixed 38px column cannot hold a relative "N분 전" string. Local time, matching
// the keeper-v2 prototype's clock format.
function clockLabel(iso: string | null): string {
  if (!iso) return ''
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ''
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

function LineageActor({ id, current = false }: { id: string | null; current?: boolean }) {
  if (!id) return html`<span class="wk-lin-actor none">미배정</span>`
  const isKeeper = findKeeper(id) !== null
  return html`<span class=${`wk-lin-actor${isKeeper ? '' : ' none'}${current ? ' cur' : ''}`}>${id}</span>`
}

function TaskLineageSection({ task }: { task: Task }) {
  const loading = taskEventsLoading.value
  const events = taskEvents.value
  // Defer to the events section's own loading affordance while the first fetch
  // is in flight, so the synthesized fallback does not flash then get replaced.
  if (loading && events.length === 0) return null

  const lineage = buildTaskLineage(events, task)
  if (lineage.rows.length === 0) return null
  const assignee = task.assignee ?? null

  return html`
    <div>
      <${SectionTitle}>활동 흐름</${SectionTitle}>
      <div class="wk-lineage">
        <div class="wk-lin-h">
          <span class="wk-lin-h-lbl">소유권 체인</span>
          <span class="wk-lin-chain">
            ${lineage.chain.length === 0
              ? html`<${LineageActor} id=${null} />`
              : lineage.chain.map((id, i) => html`
                  ${i > 0 ? html`<span class="wk-lin-chain-arr">→</span>` : null}
                  <${LineageActor} id=${id} current=${id === assignee} />
                `)}
          </span>
          ${lineage.synthesized
            ? html`<span class="text-3xs text-text-dim">상태 기반 추정 · 기록된 이벤트 없음</span>`
            : null}
        </div>
        <div class="wk-lin-track">
          ${lineage.rows.map((row, i) => html`
            <div key=${`${row.stage.key}-${i}`} class=${`wk-lin-row ${row.stage.cls}`}>
              <span class="wk-lin-at">${clockLabel(row.ts)}</span>
              <span class="wk-lin-rail"><span class=${`wk-lin-dot ${row.stage.cls}`}></span></span>
              <span class="wk-lin-body">
                <span class="wk-lin-line">
                  <span class=${`wk-lin-ev ${row.stage.cls}`}>${row.stage.glyph} ${row.stage.lbl}</span>
                  ${row.actor ? html`<${LineageActor} id=${row.actor} />` : null}
                </span>
                ${row.notes ? html`<span class="wk-lin-note"><${RichContent} text=${row.notes} previewLimit=${1} /></span>` : null}
              </span>
            </div>
          `)}
        </div>
      </div>
    </div>
  `
}

// -- Verdict Lineage (compact timeline of the verification pipeline) ---

const VERDICT_LINEAGE_LABELS = new Set([
  'submit_for_verification',
  'awaiting_verification',
  'approve',
  'approved',
  'reject',
  'rejected',
])

function verdictStageLabel(label: string): string {
  switch (label) {
    case 'submit_for_verification':
    case 'awaiting_verification': return '제출'
    case 'approve':
    case 'approved': return '승인'
    case 'reject':
    case 'rejected': return '반려'
    default: return label
  }
}

function verdictToneClass(label: string): string {
  switch (label) {
    case 'approve':
    case 'approved': return 'border-ok/30 bg-ok/10 text-ok'
    case 'reject':
    case 'rejected': return 'border-warn/30 bg-warn/10 text-warn'
    default: return 'border-[var(--accent-30)] bg-[var(--accent-10)] text-accent-fg'
  }
}

function VerdictLineageSection() {
  const events = taskEvents.value
  const verdictEvents = events
    .filter((e: NormalizedTaskEvent) => VERDICT_LINEAGE_LABELS.has(e.label))
    .sort((a: NormalizedTaskEvent, b: NormalizedTaskEvent) => {
      if (!a.ts) return 1
      if (!b.ts) return -1
      return a.ts.localeCompare(b.ts)
    })

  if (verdictEvents.length === 0) return null

  return html`
    <div>
      <${SectionTitle}>검증 진행 이력</${SectionTitle}>
      <div class=${CARD_BOX}>
        <div class="flex flex-col gap-2">
          ${verdictEvents.map((evt: NormalizedTaskEvent, i: number) => {
            const tone = verdictToneClass(evt.label)
            const stage = verdictStageLabel(evt.label)
            const key = evt.ts ? `${evt.ts}-${i}` : `${evt.label}-${i}`
            return html`
              <div key=${key} class="v2-workspace-row flex items-start gap-3">
                <span class=${`shrink-0 rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] ${tone}`}>${stage}</span>
                <div class="flex-1 min-w-0 text-2xs">
                  <div class="flex flex-wrap items-center gap-2 text-text-body">
                    ${evt.agent ? html`<span class="font-mono text-accent-fg">@${evt.agent}</span>` : html`<span class="text-text-muted">(unknown)</span>`}
                    ${evt.actorKind ? html`<span class="text-text-muted">· ${evt.actorKind}</span>` : null}
                    ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} class="text-3xs text-text-dim" />` : null}
                  </div>
                  ${evt.notes ? html`<div class="mt-1 text-3xs text-text-muted break-words"><${RichContent} text=${evt.notes} previewLimit=${1} /></div>` : null}
                </div>
              </div>
            `
          })}
        </div>
      </div>
    </div>
  `
}

function gateTone(status?: string | null): string {
  switch (status) {
    case 'ready': return 'text-ok border-ok/25 bg-ok/10'
    case 'blocked': return 'text-bad border-bad/25 bg-bad/10'
    case 'inconclusive': return 'text-warn border-warn/25 bg-warn/10'
    default: return 'text-text-muted border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'
  }
}

function GateSection({
  title,
  gate,
}: {
  title: string
  gate?: TaskGateEvaluation | null
}) {
  if (!gate) return null

  return html`
    <div class=${CARD_BOX}>
      <div class="flex items-center justify-between gap-3">
        <div class="text-xs font-medium text-text-strong">${title}</div>
        <span class=${`rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] ${gateTone(gate.status)}`}>${gate.status}</span>
      </div>
      ${gate.reasons && gate.reasons.length > 0 ? html`
        <div class="mt-2 flex flex-col gap-1">
          ${gate.reasons.slice(0, 4).map(reason => html`
            <div key=${reason} class="text-2xs leading-relaxed text-text-muted">${reason}</div>
          `)}
        </div>
      ` : null}
    </div>
  `
}

// RFC-0323 G-9: linked re-run lineage. A task created as a re-run carries
// the write-once predecessor_task_id (G-8); surface it as a link so the
// operator can walk back to the original. Clicking opens the predecessor's
// detail when it is in the loaded task list; otherwise the id renders as
// plain text (the store may window out old terminal tasks).
function PredecessorSection({ task }: { task: Task }) {
  const predecessorId = task.predecessor_task_id
  if (!predecessorId) return null
  const predecessor = tasks.value.find(t => t.id === predecessorId) ?? null
  return html`
    <div>
      <${SectionTitle}>이전 실행 (재실행 계보)</${SectionTitle}>
      <div class="${CARD_BOX} flex items-center gap-2 text-sm">
        <span class="text-2xs uppercase tracking-3 text-text-muted">predecessor</span>
        ${predecessor ? html`
          <button
            type="button"
            class="font-mono text-accent-fg underline-offset-2 hover:underline"
            onClick=${() => openTaskDetail(predecessor)}
          >${predecessorId}</button>
          <span class="truncate text-text-dim">${predecessor.title}</span>
        ` : html`
          <span class="font-mono text-text-body">${predecessorId}</span>
          <span class="text-2xs text-text-dim">(현재 목록에 없음)</span>
        `}
      </div>
    </div>
  `
}

function ContractSection({ task }: { task: Task }) {
  const contract = task.contract
  const gate = task.gate
  if (!contract && !gate) return null

  const completionItems = gate?.completion_contract ?? contract?.completion_contract ?? []
  const unmetItems = gate?.unmet_completion_contract ?? []
  const requiredEvidence = contract?.required_evidence ?? []
  const isAwaitingVerification = task.status === 'awaiting_verification'
  const verifierAssignee = isAwaitingVerification ? task.assignee : undefined

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <div class="text-2xs font-semibold uppercase tracking-3 text-text-muted">계약 게이트</div>
        <span class=${`rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] ${contract?.strict ? 'text-accent-fg border-[var(--accent-25)] bg-[var(--accent-10)]' : 'text-text-muted border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'}`}>${contract?.strict ? 'strict' : 'advisory'}</span>
        ${isAwaitingVerification ? html`
          <span class="rounded-[var(--r-1)] border border-[var(--accent-40)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-accent-fg">
            검증 대기
          </span>
        ` : null}
      </div>

      ${isAwaitingVerification ? html`
        <div class="v2-workspace-card rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-5)] px-4 py-3">
          <div class="flex items-center justify-between gap-3 flex-wrap">
            <div class="text-xs font-medium text-accent-fg">Verifier Keeper 검증 중</div>
            <a
              href=${`#workspace?section=verification&task=${encodeURIComponent(task.id)}`}
              class="rounded-[var(--r-1)] border border-[var(--accent-50)] bg-[var(--accent-10)] px-2.5 py-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-accent-fg hover:bg-[var(--accent-20)]"
              title="검증 패널에서 이 태스크를 직접 승인/반려"
            >검증에 개입 →</a>
          </div>
          <div class="mt-1 text-2xs text-text-body">
            Submitter: <span class="font-mono">${verifierAssignee ?? '(unknown)'}</span>
          </div>
          <div class="mt-0.5 text-2xs text-text-muted">
            다른 keeper가 completion_contract의 정량 기준을 독립 실측 중입니다.
            통과 시 approve_verification → done, 미충족 시 reject_verification → in_progress로 복귀.
            인간 판단이 필요하면 우측 상단 버튼으로 검증 패널에서 직접 승인/반려할 수 있습니다
            (operator: 접두어로 감사 로그에 기록).
          </div>
        </div>
      ` : null}

      <${GateSection} title="완료 게이트" gate=${gate?.done} />
      <${GateSection} title="검수 → 구현" gate=${gate?.inspect_to_implement} />
      <${GateSection} title="검증 → 리뷰" gate=${gate?.verify_to_review} />

      ${completionItems.length > 0 ? html`
        <div class=${CARD_BOX}>
          <div class="text-xs font-medium text-text-strong">완료 계약</div>
          <div class="mt-2 flex flex-col gap-1">
            ${completionItems.map((item: string) => html`
              <div key=${item} class=${`text-2xs ${unmetItems.includes(item) ? 'text-bad' : 'text-text-body'}`}>${item}</div>
            `)}
          </div>
        </div>
      ` : null}

      ${requiredEvidence.length > 0 ? html`
        <div class=${CARD_BOX}>
          <div class="text-xs font-medium text-text-strong">필수 증거</div>
          <div class="mt-2 flex flex-wrap gap-1.5">
            ${requiredEvidence.map((item: string) => html`
              <span key=${item} class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-mono text-text-body">${item}</span>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}

function ExecutionLinksSection({ task }: { task: Task }) {
  const links = task.execution_links
  const items = [
    ['session', links?.session_id],
    ['operation', links?.operation_id],
  ].filter(([, value]) => Boolean(value))

  if (items.length === 0) return null

  return html`
    <div>
      <${SectionTitle}>연결된 실행</${SectionTitle}>
      <div class="flex flex-col gap-2">
        ${items.map(([label, value]) => html`
          <div key=${label} class=${CARD_BOX}>
            <div class="text-3xs uppercase tracking-3 text-text-dim">${label}</div>
            <div class="mt-1 text-xs font-mono text-text-body break-all">${value}</div>
          </div>
        `)}
      </div>
    </div>
  `
}

function HandoffSection({ task }: { task: Task }) {
  const handoff = task.handoff_context
  if (!handoff?.summary) return null

  return html`
    <div>
      <${SectionTitle}>최근 Handoff</${SectionTitle}>
      <div class="v2-workspace-detail rounded-[var(--r-1)] border border-warn/20 bg-warn/8 px-4 py-3">
        <div class="text-sm leading-relaxed text-text-body"><${RichContent} text=${handoff.summary} previewLimit=${2} /></div>
        ${handoff.reason ? html`<div class="mt-2 text-2xs text-text-muted">reason: ${handoff.reason}</div>` : null}
        ${handoff.next_step ? html`<div class="mt-1 text-2xs text-text-muted">next: ${handoff.next_step}</div>` : null}
        ${handoff.failure_mode ? html`<div class="mt-1 text-2xs text-text-muted">failure: ${handoff.failure_mode}</div>` : null}
        ${handoff.evidence_refs && handoff.evidence_refs.length > 0 ? html`
          <div class="mt-2 flex flex-wrap gap-1.5">
            ${handoff.evidence_refs.map((item: string) => html`
              <span key=${item} class="rounded-[var(--r-1)] border border-warn/20 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-mono text-text-body">${item}</span>
            `)}
          </div>
        ` : null}
      </div>
    </div>
  `
}

// -- Goal relationship section --------------------------------------

function GoalRelationSection({ goalIds }: { goalIds: string[] }) {
  if (goalIds.length === 0) return null

  const query = goalRelationSearchQuery.value
  const visibleIds = filterGoalRelations(goalIds, query)
  const trimmed = query.trim()
  const isFiltering = trimmed !== ''

  return html`
    <div class="v2-workspace-panel flex flex-col gap-2">
      <div class="flex flex-wrap items-center gap-2">
        <div class="text-2xs font-semibold uppercase tracking-3 text-text-muted">담당 키퍼의 활성 목표</div>
        ${goalIds.length > 1 ? html`
          <${TextInput}
            type="search"
            value=${query}
            placeholder="목표 검색 (title/status/metric)"
            ariaLabel="목표 검색"
            onInput=${(e: Event) => { goalRelationSearchQuery.value = (e.target as HTMLInputElement).value }}
            class="min-w-40 max-w-60 flex-1 !px-2 !py-1 !text-2xs"
          />
          <span class="text-3xs text-[var(--color-fg-muted)] tabular-nums">
            ${isFiltering
              ? `${visibleIds.length} / ${goalIds.length}`
              : `${goalIds.length}개`}
          </span>
        ` : null}
      </div>
      ${isFiltering && visibleIds.length === 0
        ? html`<div class="py-3 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${goalIds.length} goals)</div>`
        : html`
      <div class="flex flex-col gap-1">
        ${visibleIds.map(id => {
          const goal = goalById(id)
          return html`
            <div key=${id} class="v2-workspace-row flex items-center gap-2 rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] px-3 py-2">
              <span class="text-xs text-text-body">${goal?.title ?? id}</span>
              ${goal?.status ? html`<${StatusBadge} status=${goal.status} />` : null}
            </div>
          `
        })}
      </div>
        `}
    </div>
  `
}

// -- Main overlay ---------------------------------------------------

export function TaskDetailOverlay() {
  const task = selectedTask.value
  if (!task) return null

  const closeButtonRef = useRef<HTMLButtonElement>(null)
  const titleId = `task-detail-title-${task.id}`
  const p = effectiveTaskPriority(task)
  const keeper = findKeeper(task.assignee)
  const goalIds = assigneeGoalIds(task)
  const assigneeKind = task.assignee_kind ?? (keeper ? 'keeper' : null)

  return html`
    <${DialogOverlay}
      labelledBy=${titleId}
      onClose=${closeTaskDetail}
      initialFocusRef=${closeButtonRef}
      overlayClass="fixed inset-0 z-[60] bg-[var(--dialog-overlay-bg)]/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-[var(--t-med)]"
      panelClass="v2-workspace-panel w-full max-w-[900px] max-h-[90vh] overflow-y-auto bg-[var(--color-bg-surface)] rounded-[var(--r-1)] border border-[var(--dialog-panel-border)] shadow-[0_24px_64px_var(--black-50)]"
    >
      ${'' /* Sticky Header */}
      <div class="v2-workspace-toolbar sticky top-0 z-10 flex items-center justify-between gap-4 px-6 py-4 border-b border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] backdrop-blur-sm rounded-t-[var(--r-1)]">
        <div class="flex-1 min-w-0">
          <h2 id=${titleId} class="text-lg font-semibold text-text-strong break-words">${task.title}</h2>
          <div class="mt-1.5 flex flex-wrap items-center gap-2">
            <${StatusBadge} status=${task.status ?? 'todo'} />
            <span class="rounded-[var(--r-1)] border border-current/20 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-2xs font-semibold text-text-body">${priorityLabel(p)}</span>
            ${task.assignee ? html`<span class="text-2xs text-accent-fg">@${task.assignee}${assigneeKind ? ` (${assigneeKind})` : ''}</span>` : null}
          </div>
        </div>
        <button
          ref=${closeButtonRef}
          type="button"
          class="v2-workspace-action shrink-0 size-8 flex items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-text-muted cursor-pointer transition-colors hover:bg-[var(--color-bg-hover)] hover:text-text-strong"
          onClick=${closeTaskDetail}
          aria-label="닫기"
        ><${X} size=${16} /></button>
      </div>

      ${'' /* Tab bar */}
      ${hasActivityTab(task) ? html`
        <div class="v2-workspace-toolbar flex items-center gap-1 px-6 pt-3 pb-0">
          ${(['overview', 'activity'] as TaskDetailTab[]).map(tab => html`
            <button
              key=${tab}
              type="button"
              class="v2-workspace-action px-3 py-1.5 rounded-[var(--r-1)] text-xs font-medium border cursor-pointer transition-colors ${
                activeTab.value === tab
                  ? 'border-[var(--accent-40)] bg-[var(--accent-12)] text-[var(--color-accent-fg)]'
                  : 'border-transparent text-text-muted hover:bg-[var(--color-bg-hover)]'
              }"
              onClick=${() => tab === 'activity' ? switchToActivityTab(task) : (activeTab.value = 'overview')}
            >${tab === 'overview' ? '개요' : '담당자 최근 활동'}</button>
          `)}
        </div>
      ` : null}

      ${'' /* Body */}
      <div class="flex flex-col gap-5 p-6">
        ${activeTab.value === 'overview' ? html`
          ${'' /* Description */}
          ${task.description ? html`
            <div>
              <${SectionTitle}>설명</${SectionTitle}>
              <div class="v2-workspace-detail rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-3 text-sm leading-relaxed text-text-body">
                <${RichContent} text=${task.description} previewLimit=${2} />
              </div>
            </div>
          ` : null}

          <${TaskLineageSection} task=${task} />
          <${PredecessorSection} task=${task} />
          <${ContractSection} task=${task} />
          <${VerdictLineageSection} />
          <${ExecutionLinksSection} task=${task} />
          <${HandoffSection} task=${task} />

          ${'' /* Goal relation */}
          <${GoalRelationSection} goalIds=${goalIds} />

          ${'' /* Recent task events */}
          <div>
            <${SectionTitle}>최근 태스크 이벤트</${SectionTitle}>
            <${TaskEventsSection} />
          </div>

          ${'' /* Metadata */}
          <div class="v2-workspace-row flex flex-wrap items-center gap-3 text-2xs text-text-dim border-t border-[var(--color-border-default)] pt-4">
            ${task.created_at ? html`<span>생성: <${TimeAgo} timestamp=${task.created_at} /></span>` : null}
            <span class="font-mono">${task.id}</span>
          </div>
        ` : html`
          ${'' /* Activity tab */}
          <${TaskActivityList}
            events=${activityEvents.value}
            loading=${activityLoading.value}
            error=${activityError.value}
            showToolCalls=${isKeeperAssignee(task)}
          />
        `}
      </div>
    <//>
  `
}
