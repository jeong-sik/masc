// Task detail overlay — opens when clicking a task title in the kanban board

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import { DialogOverlay } from '../common/dialog'
import { StatusBadge } from '../common/status-badge'
import { EmptyState } from '../common/empty-state'
import { LoadingState } from '../common/feedback-state'
import { TimeAgo } from '../common/time-ago'
import { findKeeper } from '../../lib/keeper-utils'
import {
  selectedTask,
  closeTaskDetail,
  taskEvents,
  taskEventsLoading,
  taskEventsError,
  assigneeGoalIds,
  type NormalizedTaskEvent,
} from './task-detail-state'
import { goalById, priorityLabel } from './goal-helpers'

// -- Event timeline (inline, NormalizedTaskEvent shape) --------------

function eventBadge(label: string): { icon: string; color: string } {
  switch (label) {
    case 'claim':
    case 'claimed': return { icon: 'C', color: 'text-accent' }
    case 'done':
    case 'completed': return { icon: '\u2713', color: 'text-ok' }
    case 'cancel':
    case 'cancelled': return { icon: '\u2715', color: 'text-bad' }
    case 'transition': return { icon: '\u2192', color: 'text-warn' }
    default: return { icon: '\u00B7', color: 'text-text-muted' }
  }
}

function TaskEventsSection() {
  const events = taskEvents.value
  const loading = taskEventsLoading.value
  const error = taskEventsError.value

  if (loading) return html`<${LoadingState}>이벤트 불러오는 중...<//>`
  if (error) return html`<div class="text-[12px] text-bad py-2">${error}</div>`
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
                ${evt.agent ? html`<span class="text-[10px] text-accent">@${evt.agent}</span>` : null}
              </div>
              ${evt.notes ? html`<div class="mt-0.5 text-[11px] text-text-muted whitespace-pre-wrap">${evt.notes}</div>` : null}
            </div>
            ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} class="text-[10px] text-text-dim shrink-0" />` : null}
          </div>
        `
      })}
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
            ${task.assignee ? html`<span class="text-[11px] text-accent">@${task.assignee}${keeper ? ' (keeper)' : ''}</span>` : null}
          </div>
        </div>
        <button
          ref=${closeButtonRef}
          type="button"
          class="shrink-0 size-8 flex items-center justify-center rounded-lg border border-[var(--white-10)] bg-[var(--white-5)] text-text-muted cursor-pointer transition-colors hover:bg-[var(--white-10)] hover:text-text-strong"
          onClick=${closeTaskDetail}
          aria-label="닫기"
        >\u2715</button>
      </div>

      ${'' /* Body */}
      <div class="flex flex-col gap-5 p-6">
        ${'' /* Description */}
        ${task.description ? html`
          <div>
            <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-text-muted mb-2">설명</div>
            <div class="text-[13px] leading-relaxed text-text-body whitespace-pre-wrap break-words">${task.description}</div>
          </div>
        ` : null}

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
      </div>
    <//>
  `
}
