// Planning main component — orchestrates goals and kanban views

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { EmptyState } from '../common/empty-state'
import { LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import {
  goals,
  goalsLoading,
  refreshGoals,
  tasksByStatus,
} from '../../store'
import {
  filteredGoals,
  groupedByHorizon,
} from './goal-helpers'
import { GoalsSummary, FilterBar, HorizonGroup } from './goal-components'
import { TaskBacklog } from './kanban-components'
import { TaskCreateForm } from '../task-manage/task-create-form'

const QUICK_START_DOC_URL = 'https://github.com/jeong-sik/masc-mcp/blob/main/docs/QUICK-START.md'
const COMMAND_PLANE_DOC_URL = 'https://github.com/jeong-sik/masc-mcp/blob/main/docs/COMMAND-PLANE-RUNBOOK.md'

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
    <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-4">
      <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-text-muted">${label}</div>
      <div class="mt-2 text-[30px] font-bold leading-none tabular-nums ${toneClass}">${value}</div>
    </div>
  `
}

function ExternalDocLink({ href, label }: { href: string; label: string }) {
  return html`
    <a
      href=${href}
      target="_blank"
      rel="noreferrer"
      class="inline-flex items-center gap-1 rounded-lg border border-card-border/70 bg-white/3 px-2.5 py-1.5 text-[11px] font-medium text-text-body transition-colors hover:border-accent/35 hover:text-text-strong"
    >
      ${label}
      <span aria-hidden="true">\u2197</span>
    </a>
  `
}

function GuideCard({
  eyebrow,
  title,
  count,
  summary,
  command,
  docHref,
  docLabel,
  children,
}: {
  eyebrow: string
  title: string
  count: number
  summary: string
  command?: string
  docHref: string
  docLabel: string
  children?: ComponentChildren
}) {
  return html`
    <section class="flex flex-col gap-3 rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-4">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-text-muted">${eyebrow}</div>
          <h3 class="mt-1 text-[15px] font-semibold text-text-strong">${title}</h3>
        </div>
        <span class="rounded-lg border border-card-border/70 bg-white/4 px-2.5 py-1 text-[11px] font-semibold text-text-body">
          ${count}
        </span>
      </div>
      <p class="text-[13px] leading-relaxed text-text-muted whitespace-pre-wrap">${summary}</p>
      ${command ? html`
        <div class="rounded-lg border border-card-border/60 bg-white/3 px-3 py-2 text-[12px] leading-relaxed text-text-body">
          <code class="text-[11px] text-text-strong">${command}</code>
        </div>
      ` : null}
      ${children}
      <div class="pt-1">
        <${ExternalDocLink} href=${docHref} label=${docLabel} />
      </div>
    </section>
  `
}

export function Planning() {
  const { todo, inProgress, done } = tasksByStatus.value
  const totalTasks = todo.length + inProgress.length + done.length
  const highPriority = [...todo, ...inProgress].filter(t => (t.priority ?? 4) <= 2).length

  const grouped = groupedByHorizon.value
  const hasGoals = goals.value.length > 0
  const onlyBacklogActive = totalTasks > 0 && !hasGoals
  const planStatusHeadline = onlyBacklogActive
    ? '지금은 backlog만 채워져 있습니다'
    : hasGoals
      ? '장기 목표와 backlog 상태를 함께 추적합니다'
      : 'backlog와 장기 목표를 함께 보는 조감도입니다'
  const planStatusBody = onlyBacklogActive
    ? '태스크가 등록되어 있습니다. 장기 목표를 추가하면 여기에 함께 표시됩니다.'
    : hasGoals
      ? '장기 목표와 태스크를 한눈에 확인합니다.'
      : '아직 등록된 항목이 없습니다.'

  return html`
    <div class="flex flex-col gap-6">
      <section class="rounded-2xl border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-[760px]">
            <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-text-muted">Planning Status</div>
            <h3 class="mt-2 text-[22px] font-semibold tracking-[-0.02em] text-text-strong">${planStatusHeadline}</h3>
            <p class="mt-2 text-[13px] leading-relaxed text-text-muted whitespace-pre-wrap">${planStatusBody}</p>
          </div>
          <${ActionButton}
            variant="ghost"
            size="md"
            disabled=${goalsLoading.value}
            onClick=${() => { refreshGoals() }}
          >
            ${goalsLoading.value ? '새로고침 중...' : '계획 데이터 새로고침'}
          <//>
        </div>

        <div class="mt-5 grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-3">
          <${PlanningStat} label="전체 태스크" value=${totalTasks} />
          <${PlanningStat} label="할 일" value=${todo.length} />
          <${PlanningStat} label="진행 중" value=${inProgress.length} tone="warn" />
          <${PlanningStat} label="완료" value=${done.length} tone="ok" />
          <${PlanningStat} label="높은 우선순위" value=${highPriority} tone=${highPriority > 0 ? 'bad' : 'default'} />
        </div>

        <div class="mt-5 grid gap-4 xl:grid-cols-2">
          <section class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-4">
            <div class="mb-3">
              <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-text-muted">Backlog Entry</div>
              <h3 class="mt-1 text-[15px] font-semibold text-text-strong">태스크 추가</h3>
            </div>
            <${TaskCreateForm} />
            <div class="mt-3 flex items-center gap-2">
              <${ExternalDocLink} href=${QUICK_START_DOC_URL} label="Quick Start" />
            </div>
          </section>

          <${GuideCard}
            eyebrow="Goal Pipeline"
            title="장기 목표 파이프라인"
            count=${goals.value.length}
            summary=${hasGoals
              ? '등록된 목표를 단기/중기/장기로 나눠 추적합니다.'
              : '등록된 목표가 없습니다. 목표를 등록하면 여기에 표시됩니다.'}
            docHref=${COMMAND_PLANE_DOC_URL}
            docLabel="Command Plane Runbook"
          />
        </div>
      </section>

      <${TaskBacklog} />

      <details class="overview-section-collapsible group overflow-hidden rounded-xl border border-card-border/60 bg-[rgba(9,14,24,0.82)]" open=${true}>
        <summary class="flex items-center gap-3 border-b border-card-border/60 px-4 py-3.5 cursor-pointer text-[14px] font-bold text-text-strong transition-colors hover:bg-white/3">
          <div class="min-w-0">
            <div>장기 목표 파이프라인</div>
            <div class="mt-1 text-[12px] font-normal text-text-muted">
              goal은 자동 생성되지 않습니다. 등록된 항목만 여기에 보입니다.
            </div>
          </div>
          <span class="ml-auto inline-flex items-center rounded-lg border border-card-border/70 bg-white/4 px-2.5 py-1 text-[10px] uppercase tracking-wider text-text-body font-semibold">${goals.value.length}</span>
        </summary>
        <div class="p-5">
          ${hasGoals ? html`
            <div class="mb-4 text-[12px] leading-relaxed text-text-muted">
              단기/중기/장기 목표를 메트릭 기준으로 구조화해 보여 줍니다.
            </div>
            <${GoalsSummary} />
            <${FilterBar} />
            ${goalsLoading.value && goals.value.length === 0
              ? html`<${LoadingState}>목표 불러오는 중...<//>`
              : filteredGoals.value.length === 0
                ? html`<${EmptyState} message="현재 필터에 맞는 목표가 없습니다" compact />`
                : html`
                    <div class="mt-3 flex flex-col gap-5">
                      <${HorizonGroup} horizon="short" items=${grouped.short ?? []} />
                      <${HorizonGroup} horizon="mid" items=${grouped.mid ?? []} />
                      <${HorizonGroup} horizon="long" items=${grouped.long ?? []} />
                    </div>
                  `}
          ` : html`
            <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-4">
              <div class="text-[14px] font-semibold text-text-strong">등록된 장기 목표가 없습니다</div>
              <div class="mt-2 text-[13px] leading-relaxed text-text-muted">
                backlog 태스크와 목표 파이프라인은 별개입니다. 장기 계획이 필요하면 목표를 등록하세요.
              </div>
              <div class="mt-3 flex flex-wrap gap-2">
                <${ExternalDocLink} href=${COMMAND_PLANE_DOC_URL} label="goal 등록 가이드" />
              </div>
            </div>
          `}
        </div>
      </details>
    </div>
  `
}
