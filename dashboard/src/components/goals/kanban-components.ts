// Kanban board components: KanbanCard, TaskBacklog

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useRef, useEffect } from 'preact/hooks'
import type { ComponentChildren } from 'preact'
import autoAnimate from '@formkit/auto-animate'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { Card } from '../common/card'
import { TextInput } from '../common/input'
import { TimeAgo } from '../common/time-ago'
import { RichContent } from '../common/rich-content'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { tasksByStatus, refreshExecution, executionLoading, executionLoaded, executionError } from '../../store'
import { deleteTask } from '../../api/actions'
import type { Task } from '../../types'
import {
  expandedTasks,
  toggleTaskExpand,
  priorityLabel,
  sortByPriority,
  sortByTimeDesc,
  taskSearchQuery,
  resetTaskSearch,
  filterTasksByQuery,
} from './goal-helpers'
import { openTaskDetail } from './task-detail-state'

const deletingTaskId = signal<string | null>(null)
const doneVisibleCount = signal(20)
const searchDoneVisibleCount = signal(20)
const DONE_PAGE_SIZE = 20
const REPO_ISSUES_BASE = 'https://github.com/jeong-sik/masc-mcp/issues'

export function resetTaskBacklogState() {
  doneVisibleCount.value = DONE_PAGE_SIZE
  searchDoneVisibleCount.value = DONE_PAGE_SIZE
}

function priorityToneClass(priority: number): string {
  switch (priority) {
    case 1: return 'border-l-[var(--rose-light)] bg-[var(--color-status-err)]/10 text-[#fecdd3]'
    case 2: return 'border-l-[var(--color-status-warn)] bg-[var(--color-status-warn)]/10 text-[var(--yellow-100)]'
    case 3: return 'border-l-[var(--blue-400)] bg-[var(--blue-400)]/10 text-[#bfdbfe]'
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

function KanbanCard({ task }: { task: Task }) {
  const p = task.priority ?? 4
  const isExpanded = expandedTasks.value.has(task.id)
  const hasDescription = Boolean(task.description)
  const isDeleting = deletingTaskId.value === task.id
  const description = task.description ?? ''
  const canExpand = description.length > 160
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
    <article class="flex flex-col gap-3 rounded border border-card-border/60 border-l-4 bg-[rgba(7,12,20,0.92)] p-4 ${priorityToneClass(p)}">
      <div class="flex items-start justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="rounded border border-current/20 px-2 py-0.5 text-2xs font-semibold">${priorityLabel(p)}</span>
          ${scope ? html`<span class="rounded border border-card-border/70 bg-white/5 px-2 py-0.5 text-2xs font-medium text-text-body">${scope}</span>` : null}
        </div>
        <${ActionButton}
          variant="danger"
          size="sm"
          onClick=${handleDelete}
          disabled=${isDeleting}
          ariaBusy=${isDeleting}
          ariaLabel=${`태스크 삭제: ${task.title}`}
        >
          ${isDeleting ? '삭제 중...' : '삭제'}
        <//>
      </div>

      <button
        type="button"
        class="text-left text-base font-semibold leading-snug text-text-strong whitespace-pre-wrap break-words cursor-pointer bg-transparent border-none p-0 font-[inherit] transition-colors hover:text-accent"
        onClick=${() => openTaskDetail(task)}
      >${task.title}</button>

      ${hasDescription ? html`
        <div class="flex flex-col gap-2">
          <div class=${`overflow-hidden text-sm leading-relaxed text-text-body ${isExpanded || !canExpand ? '' : 'max-h-[9rem]'}`}>
            <${RichContent} text=${description} previewLimit=${1} />
          </div>
          ${canExpand ? html`
            <button
              type="button"
              class="w-fit rounded border border-card-border/70 bg-white/4 px-2 py-1 text-2xs text-text-muted transition-colors hover:text-text-strong"
              onClick=${() => toggleTaskExpand(task.id)}
              aria-expanded=${isExpanded}
            >
              ${isExpanded ? '설명 접기' : '설명 더 보기'}
            </button>
          ` : null}
        </div>
      ` : html`
        <div class="text-xs text-text-dim">설명 없음</div>
      `}

      <div class="flex flex-wrap items-center gap-2 text-2xs text-text-muted">
        ${task.status === 'awaiting_verification'
          ? html`<span class="rounded border border-accent/30 bg-[var(--accent-10)] px-2 py-1 text-accent" title="verifier keeper의 독립 실측을 기다리는 중">검증 대기${task.updated_at ? html` <${TimeAgo} timestamp=${task.updated_at} />` : null}</span>`
          : task.completed_at && task.status === 'done'
            ? html`<span class="rounded border border-ok/25 bg-ok/10 px-2 py-1 text-ok">완�� <${TimeAgo} timestamp=${task.completed_at} /></span>`
            : task.completed_at && task.status === 'cancelled'
              ? html`<span class="rounded border border-[var(--bad-30)] bg-[var(--bad-10)] px-2 py-1 text-[var(--bad-light)]">취소 <${TimeAgo} timestamp=${task.completed_at} /></span>`
              : task.created_at
                ? html`<span class="rounded border border-card-border/70 bg-white/4 px-2 py-1"><${TimeAgo} timestamp=${task.created_at} /></span>`
                : null}
        ${task.assignee ? html`<span class="rounded border border-accent/20 bg-[var(--accent-10)] px-2 py-1 text-accent">@${task.assignee}</span>` : null}
        <a
          href=${link.href}
          target="_blank"
          rel="noreferrer"
          class="inline-flex items-center gap-1 rounded border border-card-border/70 bg-white/4 px-2 py-1 text-text-body transition-colors hover:border-accent/35 hover:text-text-strong"
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
    <section class="flex min-h-60 flex-col gap-4 rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label=${title}>
      <div class="flex items-start justify-between gap-3 border-b border-card-border/50 pb-3">
        <div>
          <h3 class="text-md font-semibold text-text-strong">${title}</h3>
          <p class="mt-1 text-xs leading-relaxed text-text-muted">${description}</p>
        </div>
        <span class="rounded px-2.5 py-1 text-xs font-semibold ${badgeClass}">${count}</span>
      </div>
      <div ref=${listRef} class="flex max-h-170 flex-col gap-3 overflow-y-auto pr-1 custom-scrollbar">
        ${children}
      </div>
    </section>
  `
}

export function TaskBacklog() {
  const { todo, inProgress, awaitingVerification, done } = tasksByStatus.value
  const totalTasks = todo.length + inProgress.length + awaitingVerification.length + done.length
  const query = taskSearchQuery.value
  const hasSearch = query.trim().length > 0
  const filteredTodo = filterTasksByQuery(todo, query)
  const filteredInProgress = filterTasksByQuery(inProgress, query)
  const filteredAwaitingVerification = filterTasksByQuery(awaitingVerification, query)
  const filteredDone = filterTasksByQuery(done, query)
  const filteredTotal =
    filteredTodo.length +
    filteredInProgress.length +
    filteredAwaitingVerification.length +
    filteredDone.length
  const sortedTodo = [...filteredTodo].sort(sortByPriority)
  const sortedInProgress = [...filteredInProgress].sort(sortByPriority)
  const sortedAwaitingVerification = [...filteredAwaitingVerification].sort(sortByPriority)
  const sortedDone = [...filteredDone].sort(sortByTimeDesc)
  const activeDoneVisibleCount = hasSearch ? searchDoneVisibleCount.value : doneVisibleCount.value
  const effectiveDoneVisibleCount = Math.min(activeDoneVisibleCount, sortedDone.length)
  const visibleDone = sortedDone.slice(0, effectiveDoneVisibleCount)
  const hasMoreDone = sortedDone.length > effectiveDoneVisibleCount
  const remainingDone = sortedDone.length - effectiveDoneVisibleCount
  const emptyColumnMessage = hasSearch ? '검색 결과 없음' : null

  // Reset pagination only for the base done list when data shrinks.
  if (!hasSearch && doneVisibleCount.value > sortedDone.length && doneVisibleCount.value > DONE_PAGE_SIZE) {
    doneVisibleCount.value = Math.max(DONE_PAGE_SIZE, sortedDone.length)
  }

  function setSearchQuery(nextQuery: string) {
    const nextHasSearch = nextQuery.trim().length > 0
    if (!nextHasSearch) {
      searchDoneVisibleCount.value = DONE_PAGE_SIZE
    }
    taskSearchQuery.value = nextQuery
  }

  function handleSearchInput(e: Event) {
    const target = e.target as HTMLInputElement
    setSearchQuery(target.value)
  }

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
        <div class="mb-3 rounded border border-warn/25 bg-warn/10 px-3 py-2 text-xs text-warn">마지막 갱신에 실패했습니다. 표시된 데이터가 오래되었을 수 있습니다.</div>
      ` : null}
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <div class="min-w-55 flex-1">
          <${TextInput}
            value=${query}
            placeholder="태스크 제목/설명/담당자 검색..."
            ariaLabel="태스크 검색"
            onInput=${handleSearchInput}
          />
        </div>
        ${hasSearch ? html`
          <button
            type="button"
            class="rounded border border-card-border/70 bg-white/4 px-3 py-2 text-xs text-text-muted transition-colors hover:border-accent/35 hover:text-text-strong"
            onClick=${() => {
              resetTaskSearch()
              searchDoneVisibleCount.value = DONE_PAGE_SIZE
            }}
          >검색 초기화</button>
          <span class="text-xs text-text-muted">${filteredTotal}/${totalTasks}</span>
        ` : null}
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(320px,1fr))] gap-4 items-start">
        <${TaskColumn}
          title="할 일"
          count=${sortedTodo.length}
          description="아직 claim되지 않은 태스크입니다. 우선순위가 높은 순서대로 위에 옵니다."
          badgeClass="border border-bad/25 bg-bad/10 text-bad"
        >
          ${sortedTodo.length === 0
            ? html`<${EmptyState} message=${emptyColumnMessage ?? '대기 중인 태스크가 없습니다'} compact />`
            : sortedTodo.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        <//>
        <${TaskColumn}
          title="진행 중"
          count=${sortedInProgress.length}
          description="현재 어떤 작업이 실행 중인지 확인하는 칸입니다."
          badgeClass="border border-warn/25 bg-warn/10 text-warn"
        >
          ${sortedInProgress.length === 0
            ? html`<${EmptyState} message=${emptyColumnMessage ?? '진행 중인 태스크가 없습니다'} compact />`
            : sortedInProgress.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        <//>
        <${TaskColumn}
          title="검증 대기"
          count=${sortedAwaitingVerification.length}
          description="verifier keeper가 completion_contract 정량 기준을 독립 실측 중인 태스크입니다."
          badgeClass="border border-accent/30 bg-[var(--accent-10)] text-accent"
        >
          ${sortedAwaitingVerification.length === 0
            ? html`<${EmptyState} message=${emptyColumnMessage ?? '검증 대기 중인 태스크가 없습니다'} compact />`
            : sortedAwaitingVerification.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        <//>
        <${TaskColumn}
          title="완료"
          count=${sortedDone.length}
          description="최근 완료된 태스크만 우선 노출합니다."
          badgeClass="border border-ok/25 bg-ok/10 text-ok"
        >
          ${sortedDone.length === 0
            ? html`<${EmptyState} message=${emptyColumnMessage ?? '완료된 태스크가 없습니다'} compact />`
            : visibleDone.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
          ${hasMoreDone ? html`
            <button
              type="button"
              class="w-full rounded border border-card-border/60 bg-white/3 px-3 py-2 text-xs font-medium text-text-muted transition-colors hover:border-accent/35 hover:text-text-strong"
              onClick=${() => {
                if (hasSearch) searchDoneVisibleCount.value += DONE_PAGE_SIZE
                else doneVisibleCount.value += DONE_PAGE_SIZE
              }}
            >
              완료 태스크 ${remainingDone}개 더 보기
            </button>
          ` : null}
        <//>
      </div>
    <//>
  `
}
