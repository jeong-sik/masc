// Kanban board components: KanbanCard, TaskBacklog

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useRef, useEffect } from 'preact/hooks'
import type { ComponentChildren } from 'preact'
import autoAnimate from '@formkit/auto-animate'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { SectionCard } from '../common/card'
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
  effectiveTaskPriority,
  priorityLabel,
  sortByPriority,
  sortByTimeDesc,
  taskSearchQuery,
  resetTaskSearch,
  filterTasksByQuery,
} from './task-helpers'
import { openTaskDetail } from './task-detail-state'
import { DECK_CHIP, DECK_PANEL } from './deck-classes'

const deletingTaskId = signal<string | null>(null)
const doneVisibleCount = signal(20)
const searchDoneVisibleCount = signal(20)
const DONE_PAGE_SIZE = 20
const DECK_HEAD = 'border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2'
const META_CHIP = 'rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 font-mono text-3xs'
const BACKLOG_PRESSURE_PRIORITIES = [1, 2, 3, 4] as const
const BACKLOG_STALE_THRESHOLD_HOURS: Record<number, number | undefined> = {
  1: 1,
  2: 6,
}

export type BacklogPressureRow = {
  priority: number
  count: number
  oldestAgeMs: number | null
  oldestTask: Task | null
  staleThresholdHours: number | null
  tone: 'bad' | 'warn' | 'ok' | 'idle'
}

export function resetTaskBacklogState() {
  doneVisibleCount.value = DONE_PAGE_SIZE
  searchDoneVisibleCount.value = DONE_PAGE_SIZE
}

function priorityToneClass(priority: number): string {
  switch (priority) {
    case 1: return 'border-[var(--color-err-border)] bg-[var(--color-err-soft)] text-[var(--color-err-fg)]'
    case 2: return 'border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] text-[var(--color-warn-fg)]'
    case 3: return 'border-[var(--color-info-border)] bg-[var(--color-info-soft)] text-[var(--color-info-fg)]'
    default: return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
  }
}

function pressureToneClass(row: BacklogPressureRow): string {
  switch (row.tone) {
    case 'bad': return 'border-[var(--color-err-border)] bg-[var(--color-err-soft)] text-[var(--color-err-fg)]'
    case 'warn': return 'border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] text-[var(--color-warn-fg)]'
    case 'ok': return 'border-[var(--color-info-border)] bg-[var(--color-info-soft)] text-[var(--color-info-fg)]'
    default: return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
  }
}

function taskCreatedAtMs(task: Task): number | null {
  if (!task.created_at) return null
  const ts = Date.parse(task.created_at)
  return Number.isFinite(ts) ? ts : null
}

function formatAgeMs(ageMs: number | null): string {
  if (ageMs == null) return 'unknown'
  const minutes = Math.max(0, Math.floor(ageMs / 60_000))
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return `${hours}h`
  const days = Math.floor(hours / 24)
  return `${days}d`
}

function normalizePriority(priority: number | undefined): 1 | 2 | 3 | 4 {
  return priority === 1 || priority === 2 || priority === 3 ? priority : 4
}

export function buildBacklogPressureRows(tasks: Task[], nowMs = Date.now()): BacklogPressureRow[] {
  const todoTasks = tasks.filter(
    task => task.status === 'todo' && String(task.assignee ?? '').trim() === '',
  )
  return BACKLOG_PRESSURE_PRIORITIES.map(priority => {
    const matching = todoTasks.filter(task => normalizePriority(task.priority) === priority)
    const withAge = matching
      .map(task => {
        const createdAt = taskCreatedAtMs(task)
        return {
          task,
          ageMs: createdAt == null ? null : Math.max(0, nowMs - createdAt),
        }
      })
      .sort((a, b) => {
        if (a.ageMs == null && b.ageMs == null) return a.task.id.localeCompare(b.task.id)
        if (a.ageMs == null) return 1
        if (b.ageMs == null) return -1
        return b.ageMs - a.ageMs
      })
    const oldest = withAge[0] ?? null
    const staleThresholdHours = BACKLOG_STALE_THRESHOLD_HOURS[priority] ?? null
    const stale =
      staleThresholdHours != null
      && oldest?.ageMs != null
      && oldest.ageMs >= staleThresholdHours * 60 * 60 * 1000
    const tone =
      matching.length === 0
        ? 'idle'
        : stale
          ? priority === 1 ? 'bad' : 'warn'
          : 'ok'
    return {
      priority,
      count: matching.length,
      oldestAgeMs: oldest?.ageMs ?? null,
      oldestTask: oldest?.task ?? null,
      staleThresholdHours,
      tone,
    }
  })
}

function taskScope(task: Task): string | null {
  const match = task.title.match(/^\[([^\]]+)\]/)
  if (!match) return null
  const scope = match[1] ?? ''
  return scope || null
}

function KanbanCard({ task }: { task: Task }) {
  const p = effectiveTaskPriority(task)
  const isExpanded = expandedTasks.value.has(task.id)
  const hasDescription = Boolean(task.description)
  const isDeleting = deletingTaskId.value === task.id
  const description = task.description ?? ''
  const canExpand = description.length > 160
  const scope = taskScope(task)

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
    <article class="v2-workspace-card flex flex-col gap-2 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 transition-colors hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-panel-alt)]">
      <div class="flex items-start justify-between gap-3">
        <div class="flex flex-wrap items-center gap-1.5">
          <span class="${DECK_CHIP} ${priorityToneClass(p)} font-semibold">${priorityLabel(p)}</span>
          ${scope ? html`<span class="${META_CHIP} font-medium text-[var(--color-fg-secondary)]">${scope}</span>` : null}
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
        class="v2-workspace-action cursor-pointer border-none bg-transparent p-0 text-left font-[inherit] text-sm font-semibold leading-snug text-[var(--color-fg-primary)] whitespace-pre-wrap break-words transition-colors hover:text-[var(--color-accent-fg)]"
        onClick=${() => openTaskDetail(task)}
      >${task.title}</button>

      ${hasDescription ? html`
        <div class="flex flex-col gap-2">
          <div class=${`overflow-hidden text-xs leading-relaxed text-[var(--color-fg-secondary)] ${isExpanded || !canExpand ? '' : 'max-h-[8rem]'}`}>
            <${RichContent} text=${description} previewLimit=${1} />
          </div>
          ${canExpand ? html`
            <button
              type="button"
              class="v2-workspace-action w-fit rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 font-mono text-3xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
              onClick=${() => toggleTaskExpand(task.id)}
              aria-expanded=${isExpanded}
            >
              ${isExpanded ? '설명 접기' : '설명 더 보기'}
            </button>
          ` : null}
        </div>
      ` : html`
        <div class="font-mono text-3xs text-[var(--color-fg-disabled)]">설명 없음</div>
      `}

      <div class="flex flex-wrap items-center gap-1.5 font-mono text-3xs text-[var(--color-fg-muted)]">
        ${task.status === 'awaiting_verification'
          ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] px-1.5 py-0.5 text-[var(--color-accent-fg)]" title="verifier keeper의 독립 실측을 기다리는 중">검증 대기${task.updated_at ? html` <${TimeAgo} timestamp=${task.updated_at} />` : null}</span>`
          : task.completed_at && task.status === 'done'
            ? html`<span class="rounded-[var(--r-0)] border border-ok/25 bg-ok/10 px-1.5 py-0.5 text-ok">완료 <${TimeAgo} timestamp=${task.completed_at} /></span>`
            : task.completed_at && task.status === 'cancelled'
              ? html`<span class="rounded-[var(--r-0)] border border-[var(--bad-30)] bg-[var(--bad-10)] px-1.5 py-0.5 text-[var(--bad-light)]">취소 <${TimeAgo} timestamp=${task.completed_at} /></span>`
              : task.created_at
                ? html`<span class="${META_CHIP}"><${TimeAgo} timestamp=${task.created_at} /></span>`
                : null}
        ${task.assignee ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] px-1.5 py-0.5 text-[var(--color-accent-fg)]">@${task.assignee}</span>` : null}
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
    <section class="v2-workspace-panel flex min-h-60 flex-col ${DECK_PANEL}" aria-label=${title}>
      <div class="v2-workspace-toolbar ${DECK_HEAD} flex items-start justify-between gap-3">
        <div>
          <h3 class="font-mono text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-primary)]">${title}</h3>
          <p class="mt-1 text-3xs leading-relaxed text-[var(--color-fg-muted)]">${description}</p>
        </div>
        <span class="rounded-[var(--r-0)] px-1.5 py-0.5 font-mono text-3xs font-semibold ${badgeClass}">${count}</span>
      </div>
      <div ref=${listRef} class="flex max-h-170 flex-col gap-2 overflow-y-auto p-2.5 pr-1.5 custom-scrollbar">
        ${children}
      </div>
    </section>
  `
}

function BacklogPressure({ todoTasks }: { todoTasks: Task[] }) {
  const rows = buildBacklogPressureRows(todoTasks)
  const total = rows.reduce((sum, row) => sum + row.count, 0)
  const staleRows = rows.filter(row => row.tone === 'bad' || row.tone === 'warn')
  if (total === 0) return null

  return html`
    <section class="v2-workspace-panel mb-3 ${DECK_PANEL}" aria-label="Backlog pressure">
      <div class="v2-workspace-toolbar ${DECK_HEAD} flex items-start justify-between gap-3">
        <div>
          <h3 class="font-mono text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-primary)]">Backlog Pressure</h3>
          <p class="mt-1 text-3xs leading-relaxed text-[var(--color-fg-muted)]">Unclaimed tasks grouped by priority and oldest age.</p>
        </div>
        <span class=${`rounded-[var(--r-0)] border px-1.5 py-0.5 font-mono text-3xs font-semibold ${
          staleRows.length > 0
            ? 'border-[var(--color-err-border)] bg-[var(--color-err-soft)] text-[var(--color-err-fg)]'
            : 'border-[var(--color-info-border)] bg-[var(--color-info-soft)] text-[var(--color-info-fg)]'
        }`}>${total} todo</span>
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-2 p-2.5">
        ${rows.map(row => html`
          <button
            key=${row.priority}
            type="button"
            disabled=${!row.oldestTask}
            onClick=${() => row.oldestTask ? openTaskDetail(row.oldestTask) : undefined}
            class=${`v2-workspace-action min-h-22 rounded-[var(--r-0)] border p-2 text-left transition-colors ${pressureToneClass(row)} ${row.oldestTask ? 'hover:border-[var(--color-border-strong)]' : 'opacity-60'}`}
            aria-label=${`${priorityLabel(row.priority)} backlog pressure: ${row.count} unclaimed`}
          >
            <div class="flex items-center justify-between gap-2">
              <span class="font-mono text-2xs font-semibold">${priorityLabel(row.priority)}</span>
              <span class="font-mono text-2xs font-semibold">${row.count}</span>
            </div>
            <div class="mt-2 font-mono text-3xs uppercase">oldest ${formatAgeMs(row.oldestAgeMs)}</div>
            <div class="mt-1 truncate text-3xs">
              ${row.count === 0
                ? 'clear'
                : row.staleThresholdHours == null
                  ? 'watch'
                  : row.tone === 'bad' || row.tone === 'warn'
                    ? `breached ${row.staleThresholdHours}h`
                    : `within ${row.staleThresholdHours}h`}
            </div>
          </button>
        `)}
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
    return html`<${SectionCard} label="태스크 백로그" class="section" variant="compact"><${LoadingState}>백로그 불러오는 중...<//><//>`
  }

  if (hasError && !hasData) {
    return html`
      <${SectionCard} label="태스크 백로그" class="section" variant="compact">
        <div class="flex flex-col items-center gap-3 py-6">
          <${ErrorState} message="데이터를 불러오지 못했습니다." />
          <${ActionButton} variant="ghost" size="sm" onClick=${() => refreshExecution({ force: true })}>재시도<//>
        </div>
      <//>
    `
  }

  if (hasData && totalTasks === 0) {
    return html`<${SectionCard} label="태스크 백로그" class="section" variant="compact"><${EmptyState} message="등록된 태스크가 없습니다" /><//>`
  }

  return html`
    <${SectionCard} label="태스크 백로그" class="section" variant="compact">
      ${hasError && hasData ? html`
        <div class="v2-workspace-panel mb-2 rounded-[var(--r-0)] border border-warn/25 bg-warn/10 px-2.5 py-1.5 text-2xs text-warn">마지막 갱신에 실패했습니다. 표시된 데이터가 오래되었을 수 있습니다.</div>
      ` : null}
      <div class="v2-workspace-toolbar mb-3 flex flex-wrap items-center gap-2">
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
            class="v2-workspace-action rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-2 font-mono text-3xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
            onClick=${() => {
              resetTaskSearch()
              searchDoneVisibleCount.value = DONE_PAGE_SIZE
            }}
          >검색 초기화</button>
          <span class="font-mono text-3xs text-[var(--color-fg-muted)]">${filteredTotal}/${totalTasks}</span>
        ` : null}
      </div>
      <${BacklogPressure} todoTasks=${todo} />
      <div class="grid grid-cols-[repeat(auto-fit,minmax(300px,1fr))] gap-3 items-start">
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
          badgeClass="border border-[var(--accent-30)] bg-[var(--accent-10)] text-accent-fg"
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
              class="v2-workspace-action w-full rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1.5 font-mono text-3xs font-medium text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
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
