// Task detail overlay — opens when clicking a task title in the kanban board

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import { Check, X, ArrowRight, Dot, UserPlus } from 'lucide-preact'
import { DialogOverlay } from '../common/dialog'
import { StatusBadge } from '../common/status-badge'
import { EmptyState } from '../common/empty-state'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { RichContent } from '../common/rich-content'
import { TimeAgo } from '../common/time-ago'
import { findKeeper } from '../../lib/keeper-utils'
import {
  selectedTask,
  closeTaskDetail,
  taskEvents,
  taskEventsLoading,
  taskEventsError,
  assigneeGoalIds,
  activeTab,
  switchToActivityTab,
  activityEvents,
  activityLoading,
  activityError,
  hasActivityTab,
  isKeeperAssignee,
  type NormalizedTaskEvent,
  type TaskDetailTab,
} from './task-detail-state'
import { TaskActivityList } from './task-activity-list'
import { goalById, priorityLabel } from './goal-helpers'
import type { Task, TaskGateEvaluation } from '../../types'

// -- Event timeline (inline, NormalizedTaskEvent shape) --------------

function eventBadge(label: string): { icon: any; color: string } {
  switch (label) {
    case 'claim':
    case 'claimed': return { icon: html`<${UserPlus} size=${14} />`, color: 'text-accent' }
    case 'done':
    case 'completed': return { icon: html`<${Check} size=${14} />`, color: 'text-ok' }
    case 'cancel':
    case 'cancelled': return { icon: html`<${X} size=${14} />`, color: 'text-bad' }
    case 'submit_for_verification':
    case 'awaiting_verification': return { icon: html`<${ArrowRight} size=${14} />`, color: 'text-accent' }
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

  if (loading) return html`<${LoadingState}>이벤트 불러오는 중...<//>`
  if (error) return html`<${ErrorState} message=${error} />`
  if (events.length === 0) return html`<${EmptyState} message="기록된 이벤트가 없습니다" compact />`

  return html`
    <div class="flex flex-col gap-0.5">
      ${events.map((evt: NormalizedTaskEvent, i: number) => {
        const { icon, color } = eventBadge(evt.label)
        return html`
          <div key=${i} class="flex items-start gap-3 py-2 px-3 rounded-lg hover:bg-[var(--white-3)] transition-colors">
            <div class="size-7 shrink-0 rounded-md bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-[11px] font-mono font-bold ${color}">
              ${icon}
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-[12px] font-medium text-text-strong">${evt.label}</span>
                ${evt.agent ? html`<span class="text-[10px] text-accent">@${evt.agent}${evt.actorKind ? ` · ${evt.actorKind}` : ''}</span>` : null}
              </div>
              ${evt.notes ? html`<div class="mt-1 text-[11px] text-text-muted"><${RichContent} text=${evt.notes} previewLimit=${1} /></div>` : null}
            </div>
            ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} class="text-[10px] text-text-dim shrink-0" />` : null}
          </div>
        `
      })}
    </div>
  `
}

function gateTone(status?: string | null): string {
  switch (status) {
    case 'ready': return 'text-ok border-ok/25 bg-ok/10'
    case 'blocked': return 'text-bad border-bad/25 bg-bad/10'
    case 'inconclusive': return 'text-warn border-warn/25 bg-warn/10'
    default: return 'text-text-muted border-[var(--white-10)] bg-[var(--white-5)]'
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
    <div class="rounded-xl border border-[var(--white-10)] bg-[var(--white-3)] px-4 py-3">
      <div class="flex items-center justify-between gap-3">
        <div class="text-[12px] font-medium text-text-strong">${title}</div>
        <span class=${`rounded-md border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.08em] ${gateTone(gate.status)}`}>${gate.status}</span>
      </div>
      ${gate.reasons && gate.reasons.length > 0 ? html`
        <div class="mt-2 flex flex-col gap-1">
          ${gate.reasons.slice(0, 4).map(reason => html`
            <div key=${reason} class="text-[11px] leading-relaxed text-text-muted">${reason}</div>
          `)}
        </div>
      ` : null}
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
        <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-text-muted">계약 게이트</div>
        <span class=${`rounded-md border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.08em] ${contract?.strict ? 'text-accent border-accent/25 bg-[var(--accent-10)]' : 'text-text-muted border-[var(--white-10)] bg-[var(--white-5)]'}`}>${contract?.strict ? 'strict' : 'advisory'}</span>
        ${isAwaitingVerification ? html`
          <span class="rounded-md border border-accent/40 bg-[var(--accent-10)] px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.08em] text-accent">
            검증 대기
          </span>
        ` : null}
      </div>

      ${isAwaitingVerification ? html`
        <div class="rounded-xl border border-accent/30 bg-[var(--accent-5)] px-4 py-3">
          <div class="text-[12px] font-medium text-accent">Verifier Keeper 검증 중</div>
          <div class="mt-1 text-[11px] text-text-body">
            Submitter: <span class="font-mono">${verifierAssignee ?? '(unknown)'}</span>
          </div>
          <div class="mt-0.5 text-[11px] text-text-muted">
            다른 keeper가 completion_contract의 정량 기준을 독립 실측 중입니다.
            통과 시 approve_verification → done, 미충족 시 reject_verification → in_progress로 복귀.
          </div>
        </div>
      ` : null}

      <${GateSection} title="Done Gate" gate=${gate?.done} />
      <${GateSection} title="Inspect → Implement" gate=${gate?.inspect_to_implement} />
      <${GateSection} title="Verify → Review" gate=${gate?.verify_to_review} />

      ${completionItems.length > 0 ? html`
        <div class="rounded-xl border border-[var(--white-10)] bg-[var(--white-3)] px-4 py-3">
          <div class="text-[12px] font-medium text-text-strong">Completion Contract</div>
          <div class="mt-2 flex flex-col gap-1">
            ${completionItems.map((item: string) => html`
              <div key=${item} class=${`text-[11px] ${unmetItems.includes(item) ? 'text-bad' : 'text-text-body'}`}>${item}</div>
            `)}
          </div>
        </div>
      ` : null}

      ${requiredEvidence.length > 0 ? html`
        <div class="rounded-xl border border-[var(--white-10)] bg-[var(--white-3)] px-4 py-3">
          <div class="text-[12px] font-medium text-text-strong">Required Evidence</div>
          <div class="mt-2 flex flex-wrap gap-1.5">
            ${requiredEvidence.map((item: string) => html`
              <span key=${item} class="rounded-md border border-[var(--white-10)] bg-[var(--white-5)] px-2 py-0.5 text-[10px] font-mono text-text-body">${item}</span>
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
    ['autoresearch', links?.autoresearch_loop_id],
  ].filter(([, value]) => Boolean(value))

  if (items.length === 0) return null

  return html`
    <div>
      <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-text-muted mb-2">연결된 실행</div>
      <div class="flex flex-col gap-2">
        ${items.map(([label, value]) => html`
          <div key=${label} class="rounded-xl border border-[var(--white-10)] bg-[var(--white-3)] px-4 py-3">
            <div class="text-[10px] uppercase tracking-[0.12em] text-text-dim">${label}</div>
            <div class="mt-1 text-[12px] font-mono text-text-body break-all">${value}</div>
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
      <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-text-muted mb-2">최근 Handoff</div>
      <div class="rounded-xl border border-warn/20 bg-warn/8 px-4 py-3">
        <div class="text-[13px] leading-relaxed text-text-body"><${RichContent} text=${handoff.summary} previewLimit=${2} /></div>
        ${handoff.reason ? html`<div class="mt-2 text-[11px] text-text-muted">reason: ${handoff.reason}</div>` : null}
        ${handoff.next_step ? html`<div class="mt-1 text-[11px] text-text-muted">next: ${handoff.next_step}</div>` : null}
        ${handoff.failure_mode ? html`<div class="mt-1 text-[11px] text-text-muted">failure: ${handoff.failure_mode}</div>` : null}
        ${handoff.evidence_refs && handoff.evidence_refs.length > 0 ? html`
          <div class="mt-2 flex flex-wrap gap-1.5">
            ${handoff.evidence_refs.map((item: string) => html`
              <span key=${item} class="rounded-md border border-warn/20 bg-[var(--white-5)] px-2 py-0.5 text-[10px] font-mono text-text-body">${item}</span>
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

  return html`
    <div class="flex flex-col gap-2">
      <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-text-muted">담당 키퍼의 활성 목표</div>
      <div class="flex flex-col gap-1">
        ${goalIds.map(id => {
          const goal = goalById(id)
          return html`
            <div key=${id} class="flex items-center gap-2 rounded-lg border border-card-border/50 bg-[var(--white-3)] px-3 py-2">
              <span class="text-[12px] text-text-body">${goal?.title ?? id}</span>
              ${goal?.status ? html`<${StatusBadge} status=${goal.status} />` : null}
            </div>
          `
        })}
      </div>
    </div>
  `
}

// -- Main overlay ---------------------------------------------------

export function TaskDetailOverlay() {
  const task = selectedTask.value
  if (!task) return null

  const closeButtonRef = useRef<HTMLButtonElement>(null)
  const titleId = `task-detail-title-${task.id}`
  const p = task.priority ?? 4
  const keeper = findKeeper(task.assignee)
  const goalIds = assigneeGoalIds(task)
  const assigneeKind = task.assignee_kind ?? (keeper ? 'keeper' : null)

  return html`
    <${DialogOverlay}
      labelledBy=${titleId}
      onClose=${closeTaskDetail}
      initialFocusRef=${closeButtonRef}
      overlayClass="fixed inset-0 z-[60] bg-black/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-200"
      panelClass="w-full max-w-[900px] max-h-[90vh] overflow-y-auto bg-[#0d1526] rounded-2xl border border-[var(--card-border)] shadow-[0_24px_64px_rgba(0,0,0,0.5)]"
    >
      ${'' /* Sticky Header */}
      <div class="sticky top-0 z-10 flex items-center justify-between gap-4 px-6 py-4 border-b border-[var(--card-border)] bg-[rgba(13,21,38,0.97)] backdrop-blur-md rounded-t-2xl">
        <div class="flex-1 min-w-0">
          <h2 id=${titleId} class="text-[16px] font-semibold text-text-strong break-words">${task.title}</h2>
          <div class="mt-1.5 flex flex-wrap items-center gap-2">
            <${StatusBadge} status=${task.status ?? 'todo'} />
            <span class="rounded-md border border-current/20 bg-[var(--white-5)] px-2 py-0.5 text-[11px] font-semibold text-text-body">${priorityLabel(p)}</span>
            ${task.assignee ? html`<span class="text-[11px] text-accent">@${task.assignee}${assigneeKind ? ` (${assigneeKind})` : ''}</span>` : null}
          </div>
        </div>
        <button
          ref=${closeButtonRef}
          type="button"
          class="shrink-0 size-8 flex items-center justify-center rounded-lg border border-[var(--white-10)] bg-[var(--white-5)] text-text-muted cursor-pointer transition-colors hover:bg-[var(--white-10)] hover:text-text-strong"
          onClick=${closeTaskDetail}
          aria-label="닫기"
        ><${X} size=${16} /></button>
      </div>

      ${'' /* Tab bar */}
      ${hasActivityTab(task) ? html`
        <div class="flex items-center gap-1 px-6 pt-3 pb-0">
          ${(['overview', 'activity'] as TaskDetailTab[]).map(tab => html`
            <button
              key=${tab}
              type="button"
              class="px-3 py-1.5 rounded-lg text-[12px] font-medium border cursor-pointer transition-colors ${
                activeTab.value === tab
                  ? 'border-accent/40 bg-accent/12 text-[var(--accent)]'
                  : 'border-transparent text-text-muted hover:bg-[var(--white-8)]'
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
              <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-text-muted mb-2">설명</div>
              <div class="rounded-xl border border-[var(--white-10)] bg-[var(--white-3)] px-4 py-3 text-[13px] leading-relaxed text-text-body">
                <${RichContent} text=${task.description} previewLimit=${2} />
              </div>
            </div>
          ` : null}

          <${ContractSection} task=${task} />
          <${ExecutionLinksSection} task=${task} />
          <${HandoffSection} task=${task} />

          ${'' /* Goal relation */}
          <${GoalRelationSection} goalIds=${goalIds} />

          ${'' /* Recent task events */}
          <div>
            <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-text-muted mb-2">최근 태스크 이벤트</div>
            <${TaskEventsSection} />
          </div>

          ${'' /* Metadata */}
          <div class="flex flex-wrap items-center gap-3 text-[11px] text-text-dim border-t border-[var(--card-border)] pt-4">
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
