// Planning main component — task backlog and keeper activity.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { EmptyState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { normalizeToolName } from '../tool-call-shared'
import {
  planningLoading,
  refreshPlanning,
  tasksByStatus,
  keepers,
} from '../../store'
import { navigate } from '../../router'
import { effectiveTaskPriority, HIGH_TASK_PRIORITY_MAX } from './task-helpers'
import { TaskBacklog } from './kanban-components'
import { TaskStaleAlert } from './task-stale-alert'
import { TaskWall } from './task-wall'
import { TaskCreateForm } from '../task-manage/task-create-form'
import { DECK_CHIP, DECK_LABEL, DECK_PANEL } from './deck-classes'

const QUICK_START_DOC_URL = 'https://github.com/jeong-sik/masc/blob/main/docs/QUICK-START.md'
const DECK_HEAD = 'flex flex-wrap items-start justify-between gap-3 border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2.5 shadow-[inset_0_2px_0_var(--color-accent-fg)]'
const DECK_CARD = 'rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3'

function PlanningStat({
  label,
  value,
  tone = 'default',
}: {
  label: string
  value: string | number
  tone?: 'default' | 'bad' | 'warn' | 'ok'
}) {
  const toneClass =
    tone === 'bad'
      ? 'text-bad'
      : tone === 'warn'
        ? 'text-warn'
        : tone === 'ok'
          ? 'text-ok'
          : 'text-text-strong'

  return html`
    <div class="${DECK_CARD}">
      <div class="${DECK_LABEL}">${label}</div>
      <div class="mt-1 font-mono text-2xl font-semibold leading-none tabular-nums ${toneClass}">${value}</div>
    </div>
  `
}

function ExternalDocLink({ href, label }: { href: string; label: string }) {
  return html`
    <a
      href=${href}
      target="_blank"
      rel="noreferrer"
      class="v2-mobile-operator-target inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 font-mono text-3xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
    >
      ${label}
      <span aria-hidden="true">↗</span>
    </a>
  `
}

function KeeperToolActivity() {
  const keeperList = keepers.value
  if (keeperList.length === 0) return null

  const activeKeepers = useMemo(() =>
    keeperList.filter(k => {
      const stage = k.pipeline_stage ?? 'idle'
      return stage !== 'offline' && stage !== 'idle'
    }),
    [keeperList],
  )

  const { topTools, totalToolTurns } = useMemo(() => {
    const toolCounts = new Map<string, number>()
    let turns = 0
    for (const keeper of keeperList) {
      turns += keeper.autonomous_tool_turn_count ?? 0
      for (const item of keeper.metrics_window?.top_tools ?? []) {
        const name = item.tool ?? ''
        if (name) toolCounts.set(name, (toolCounts.get(name) ?? 0) + (item.count ?? 1))
      }
    }
    return {
      topTools: [...toolCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8),
      totalToolTurns: turns,
    }
  }, [keeperList])

  return html`
    <details class="overview-section-collapsible group ${DECK_PANEL}" open=${true}>
      <summary class="flex cursor-pointer items-center gap-3 border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2.5 text-sm font-semibold text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-panel-alt)]">
        <div class="min-w-0">
          <div>도구 활동 요약</div>
          <div class="mt-1 text-2xs font-normal text-[var(--color-fg-muted)]">keeper가 최근 사용한 도구와 활동 현황. 상세는 keeper 클릭.</div>
        </div>
        <span class="ml-auto inline-flex items-center ${DECK_CHIP} font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">
          ${totalToolTurns} calls
        </span>
      </summary>
      <div class="p-3">
        ${activeKeepers.length > 0 ? html`
          <div class="mb-3">
            <div class="${DECK_LABEL} mb-2">활성 keeper</div>
            <div class="flex flex-wrap gap-1.5">
              ${activeKeepers.map(keeper => html`
                <button
                  key=${keeper.name}
                  type="button"
                  class="inline-flex items-center gap-1.5 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 font-mono text-3xs text-[var(--color-fg-secondary)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
                  onClick=${() => navigate('monitoring', { section: 'agents', keeper: keeper.name })}
                >
                  ${keeper.emoji ?? ''} ${keeper.koreanName ?? keeper.name}
                  <span class="text-[var(--color-fg-disabled)]">${keeper.turn_count ?? 0}t</span>
                </button>
              `)}
            </div>
          </div>
        ` : null}
        ${topTools.length > 0 ? html`
          <div>
            <div class="${DECK_LABEL} mb-2">최근 자주 사용된 도구</div>
            <div class="grid grid-cols-[repeat(auto-fill,minmax(180px,1fr))] gap-1">
              ${topTools.map(([name, count]) => html`
                <div key=${name} class="flex items-center justify-between rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-3xs">
                  <span class="truncate font-mono text-[var(--color-fg-secondary)]">${normalizeToolName(name)}</span>
                  <span class="ml-2 flex-shrink-0 font-mono text-[var(--color-fg-disabled)]">${count}</span>
                </div>
              `)}
            </div>
          </div>
        ` : html`<${EmptyState} message="도구 호출 데이터가 아직 없습니다" compact />`}
      </div>
    </details>
  `
}

export function Planning() {
  const { todo, inProgress, done } = tasksByStatus.value
  const totalTasks = todo.length + inProgress.length + done.length
  const highPriority = [...todo, ...inProgress].filter(
    task => effectiveTaskPriority(task) <= HIGH_TASK_PRIORITY_MAX,
  ).length
  const headline = totalTasks > 0
    ? '태스크 backlog를 추적합니다'
    : '아직 등록된 태스크가 없습니다'
  const body = totalTasks > 0
    ? '태스크 상태와 실행 주체를 하나의 backlog에서 확인합니다.'
    : '새 태스크를 추가하면 이 화면에서 상태를 추적할 수 있습니다.'

  return html`
    <div class="v2-workspace-surface flex flex-col gap-4">
      <section class="${DECK_PANEL}" aria-label="계획 상태 요약">
        <div class="${DECK_HEAD}">
          <div class="max-w-190">
            <div class="${DECK_LABEL}">계획 상태</div>
            <h3 class="mt-1 text-lg font-semibold text-[var(--color-fg-primary)]">${headline}</h3>
            <p class="mt-1 text-xs leading-relaxed text-[var(--color-fg-muted)] whitespace-pre-wrap">${body}</p>
          </div>
          <${ActionButton}
            variant="ghost"
            size="md"
            class="v2-workspace-action"
            disabled=${planningLoading.value}
            onClick=${() => { void refreshPlanning() }}
          >
            ${planningLoading.value ? '새로고침 중...' : '계획 데이터 새로고침'}
          <//>
        </div>
        <div class="p-3">
          <div class="grid grid-cols-[repeat(auto-fit,minmax(128px,1fr))] gap-2">
            <${PlanningStat} label="전체 태스크" value=${totalTasks} />
            <${PlanningStat} label="할 일" value=${todo.length} />
            <${PlanningStat} label="진행 중" value=${inProgress.length} tone="warn" />
            <${PlanningStat} label="완료" value=${done.length} tone="ok" />
            <${PlanningStat} label="높은 우선순위" value=${highPriority} tone=${highPriority > 0 ? 'bad' : 'default'} />
          </div>
          <section class="mt-3 ${DECK_CARD}" aria-label="태스크 추가">
            <div class="mb-2">
              <div class="${DECK_LABEL}">백로그 항목</div>
              <h3 class="mt-1 text-sm font-semibold text-[var(--color-fg-primary)]">태스크 추가</h3>
            </div>
            <${TaskCreateForm} />
            <div class="mt-2"><${ExternalDocLink} href=${QUICK_START_DOC_URL} label="빠른 시작" /></div>
          </section>
        </div>
      </section>
      <${TaskStaleAlert} />
      <${TaskBacklog} />
      <${TaskWall} />
      <${KeeperToolActivity} />
    </div>
  `
}
