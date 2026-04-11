// Kanban board components: KanbanCard, TaskBacklog

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useRef, useEffect } from 'preact/hooks'
import type { ComponentChildren } from 'preact'
import autoAnimate from '@formkit/auto-animate'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { Card } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { tasksByStatus, refreshExecution, executionLoading, executionLoaded, executionError } from '../../store'
import { deleteTask } from '../../api/actions'
import type { Task } from '../../types'
import { truncate } from '../../lib/truncate'
import {
  expandedTasks,
  toggleTaskExpand,
  priorityLabel,
  sortByPriority,
  sortByTimeDesc,
} from './goal-helpers'
import { openTaskDetail } from './task-detail-state'

const deletingTaskId = signal<string | null>(null)
const REPO_ISSUES_BASE = 'https://github.com/jeong-sik/masc-mcp/issues'

function priorityToneClass(priority: number): string {
  switch (priority) {
    case 1: return 'border-l-[#fb7185] bg-[var(--bad)]/10 text-[#fecdd3]'
    case 2: return 'border-l-[#fbbf24] bg-[var(--warn)]/10 text-[#fde68a]'
    case 3: return 'border-l-[#60a5fa] bg-[#60a5fa]/10 text-[#bfdbfe]'
    default: return 'border-l-[rgba(148,163,184,0.45)] bg-white/5 text-text-muted'
  }
}

function taskScope(task: Task): string | null {
  const match = task.title.match(/^\[([^\]]+)\]/)
  if (!match) return null
  const scope = match[1] ?? ''
  return /^\#\d+$/.test(scope) ? null : scope || null
}

function taskLink(task: Task): { href: string; label: string } {
  const issueMatch = task.title.match(/\[#(\d+)\]/)
  if (issueMatch) {
    return {
      href: `${REPO_ISSUES_BASE}/${issueMatch[1]}`,
      label: `GitHub #${issueMatch[1]}`,
    }
  }

  const query = encodeURIComponent(task.title.replace(/^\[[^\]]+\]\s*/, '').trim())
  return {
    href: `${REPO_ISSUES_BASE}?q=${query}`,
    label: '관련 이슈 검색',
  }
}

export function KanbanCard({ task }: { task: Task }) {
  const p = task.priority ?? 4
  const isExpanded = expandedTasks.value.has(task.id)
  const hasDescription = Boolean(task.description)
  const isDeleting = deletingTaskId.value === task.id
  const description = task.description ?? ''
  const canExpand = description.length > 140
  const preview = isExpanded || !canExpand ? description : truncate(description, 140)
  const scope = taskScope(task)
  const link = taskLink(task)

  async function handleDelete(e: Event) {
    e.stopPropagation()
    const confirmed = await requestConfirm({
      title: '태스크 삭제',
      message: `"${task.title}" 태스크를 삭제하시겠습니까?`,
      tone: 'danger'
    })
    if (!confirmed) return
    deletingTaskId.value = task.id
    try {
      await deleteTask(task.id)
      showToast('태스크를 삭제했습니다', 'success')
      await refreshExecution({ force: true })
    } catch {
      showToast('태스크 삭제에 실패했습니다', 'error')
    } finally {
      deletingTaskId.value = null
    }
  }

  return html`
    <article class="flex flex-col gap-3 rounded-xl border border-card-border/60 border-l-4 bg-[rgba(7,12,20,0.92)] p-4 ${priorityToneClass(p)}">
      <div class="flex items-start justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="rounded-md border border-current/20 px-2 py-0.5 text-[11px] font-semibold">${priorityLabel(p)}</span>
          ${scope ? html`<span class="rounded-md border border-card-border/70 bg-white/5 px-2 py-0.5 text-[11px] font-medium text-text-body">${scope}</span>` : null}
        </div>
        <button
          type="button"
          class="rounded-lg border border-[var(--bad-30)] bg-[var(--bad-10)] px-2 py-1 text-[10px] font-semibold text-[var(--bad-light)] transition-colors hover:bg-[rgba(239,68,68,0.16)] disabled:opacity-50 disabled:cursor-not-allowed"
          onClick=${handleDelete}
          disabled=${isDeleting}
        >
          ${isDeleting ? '삭제 중...' : '삭제'}
        </button>
      </div>

      <button
        type="button"
        class="text-left text-[14px] font-semibold leading-snug text-text-strong whitespace-pre-wrap break-words cursor-pointer bg-transparent border-none p-0 font-[inherit] transition-colors hover:text-accent"
        onClick=${() => openTaskDetail(task)}
      >${task.title}</button>

      ${hasDescription ? html`
        <div class="flex flex-col gap-2">
          <div class="text-[13px] leading-relaxed text-text-body whitespace-pre-wrap break-words">${preview}</div>
          ${canExpand ? html`
            <button
              type="button"
              class="w-fit rounded-md border border-card-border/70 bg-white/4 px-2 py-1 text-[11px] text-text-muted transition-colors hover:text-text-strong"
              onClick=${() => toggleTaskExpand(task.id)}
            >
              ${isExpanded ? '설명 접기' : '설명 더 보기'}
            </button>
          ` : null}
        </div>
      ` : html`
        <div class="text-[12px] text-text-dim">설명 없음</div>
      `}

      <div class="flex flex-wrap items-center gap-2 text-[11px] text-text-muted">
        ${task.completed_at && task.status === 'done'
          ? html`<span class="rounded-md border border-ok/25 bg-ok/10 px-2 py-1 text-ok">완�� <${TimeAgo} timestamp=${task.completed_at} /></span>`
          : task.completed_at && task.status === 'cancelled'
            ? html`<span class="rounded-md border border-[var(--bad-30)] bg-[var(--bad-10)] px-2 py-1 text-[var(--bad-light)]">취소 <${TimeAgo} timestamp=${task.completed_at} /></span>`
            : task.created_at
              ? html`<span class="rounded-md border border-card-border/70 bg-white/4 px-2 py-1"><${TimeAgo} timestamp=${task.created_at} /></span>`
              : null}
        ${task.assignee ? html`<span class="rounded-md border border-accent/20 bg-[var(--accent-10)] px-2 py-1 text-accent">@${task.assignee}</span>` : null}
        <a
          href=${link.href}
          target="_blank"
          rel="noreferrer"
          class="inline-flex items-center gap-1 rounded-md border border-card-border/70 bg-white/4 px-2 py-1 text-text-body transition-colors hover:border-accent/35 hover:text-text-strong"
        >
          ${link.label}
          <span aria-hidden="true">\u2197</span>
        </a>
      </div>
    </article>
  `
}

function TaskColumn({
  title,
  count,
  description,
  badgeClass,
  children,
}: {
  title: string
  count: number
  description: string
  badgeClass: string
  children: ComponentChildren
}) {
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (listRef.current) {
      autoAnimate(listRef.current, { duration: 250, easing: 'ease-out' })
    }
  }, [listRef])

  return html`
    <section class="flex min-h-[240px] flex-col gap-4 rounded-2xl border border-card-border/60 bg-[rgba(9,14,24,0.82)] p-4">
      <div class="flex items-start justify-between gap-3 border-b border-card-border/50 pb-3">
        <div>
          <h3 class="text-[15px] font-semibold text-text-strong">${title}</h3>
          <p class="mt-1 text-[12px] leading-relaxed text-text-muted">${description}</p>
        </div>
        <span class="rounded-lg px-2.5 py-1 text-[12px] font-semibold ${badgeClass}">${count}</span>
      </div>
      <div ref=${listRef} class="flex max-h-[680px] flex-col gap-3 overflow-y-auto pr-1 custom-scrollbar">
        ${children}
      </div>
    </section>
  `
}

export function TaskBacklog() {
  const { todo, inProgress, done } = tasksByStatus.value
  const totalTasks = todo.length + inProgress.length + done.length
  const sortedTodo = [...todo].sort(sortByPriority)
  const sortedInProgress = [...inProgress].sort(sortByPriority)
  const sortedDone = [...done].sort(sortByTimeDesc)

  const isLoading = executionLoading.value && !executionLoaded.value
  const hasError = Boolean(executionError.value)
  const hasData = executionLoaded.value

  if (isLoading) {
    return html`<${Card} title="태스크 백로그" class="section"><${LoadingState}>백로그 불러오는 중...<//><//>`
  }

  if (hasError && !hasData) {
    return html`
      <${Card} title="태스크 백로그" class="section">
        <div class="flex flex-col items-center gap-3 py-6">
          <${ErrorState} message="데이터를 불러오지 못했습니다." />
          <${ActionButton} variant="ghost" size="sm" onClick=${() => refreshExecution({ force: true })}>재시도<//>
        </div>
      <//>
    `
  }

  if (hasData && totalTasks === 0) {
    return html`<${Card} title="태스크 백로그" class="section"><${EmptyState} message="등록된 태스크가 없습니다" /><//>`
  }

  return html`
    <${Card} title="태스크 백로그" class="section">
      ${hasError && hasData ? html`
        <div class="mb-3 rounded-lg border border-warn/25 bg-warn/10 px-3 py-2 text-[12px] text-warn">마지막 갱신에 실패했습니다. 표시된 데이터가 오래되었을 수 있습니다.</div>
      ` : null}
      <div class="grid grid-cols-[repeat(auto-fit,minmax(320px,1fr))] gap-4 items-start">
        <${TaskColumn}
          title="할 일"
          count=${todo.length}
          description="아직 claim되지 않은 태스크입니다. 우선순위가 높은 순서대로 위에 옵니다."
          badgeClass="border border-bad/25 bg-bad/10 text-bad"
        >
          ${sortedTodo.length === 0
            ? html`<${EmptyState} message="대기 중인 태스크가 없습니다" compact />`
            : sortedTodo.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        <//>
        <${TaskColumn}
          title="진행 중"
          count=${inProgress.length}
          description="현재 어떤 작업이 실행 중인지 확인하는 칸입니다."
          badgeClass="border border-warn/25 bg-warn/10 text-warn"
        >
          ${sortedInProgress.length === 0
            ? html`<${EmptyState} message="진행 중인 태스크가 없습니다" compact />`
            : sortedInProgress.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        <//>
        <${TaskColumn}
          title="완료"
          count=${done.length}
          description="최근 완료된 태스크만 우선 노출합니다."
          badgeClass="border border-ok/25 bg-ok/10 text-ok"
        >
          ${sortedDone.length === 0
            ? html`<${EmptyState} message="완료된 태스크가 없습니다" compact />`
            : sortedDone.slice(0, 20).map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
          ${sortedDone.length > 20
            ? html`<${EmptyState} message=${`...외 ${sortedDone.length - 20}개 더 있음`} compact />`
            : null}
        <//>
      </div>
    <//>
  `
}
