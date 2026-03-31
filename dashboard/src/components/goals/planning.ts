// Planning main component — orchestrates goals, MDAL, and kanban views

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { EmptyState } from '../common/empty-state'
import { LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import {
  goals,
  goalsLoading,
  mdalLoading,
  mdalSnapshotState,
  lastMdalError,
  refreshGoals,
  refreshMdal,
  tasksByStatus,
} from '../../store'
import {
  filteredGoals,
  groupedByHorizon,
  loopsList,
} from './goal-helpers'
import { GoalsSummary, FilterBar, HorizonGroup } from './goal-components'
import { LoopRow, MdalStartFormButton, MdalStartFormDialog, showMdalStartForm } from './mdal-components'
import { TaskBacklog } from './kanban-components'
import { TaskCreateForm } from '../task-manage/task-create-form'

const QUICK_START_DOC_URL = 'https://github.com/jeong-sik/masc-mcp/blob/main/docs/QUICK-START.md'
const COMMAND_PLANE_DOC_URL = 'https://github.com/jeong-sik/masc-mcp/blob/main/docs/COMMAND-PLANE-RUNBOOK.md'
const MDAL_DOC_URL = 'https://github.com/jeong-sik/masc-mcp/blob/main/docs/MDAL-LONG-TERM-PLAN-STATUS.md'

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
  command: string
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
      <p class="text-[13px] leading-relaxed text-text-muted">${summary}</p>
      <div class="rounded-lg border border-card-border/60 bg-white/3 px-3 py-2 text-[12px] leading-relaxed text-text-body">
        <code class="text-[11px] text-text-strong">${command}</code>
      </div>
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
  const loops = loopsList.value
  const hasGoals = goals.value.length > 0
  const hasLoops = loops.length > 0
  const mdalState = mdalSnapshotState.value
  const onlyBacklogActive = totalTasks > 0 && !hasGoals && !hasLoops
  const planStatusHeadline = onlyBacklogActive
    ? '지금은 backlog만 채워져 있습니다'
    : !hasGoals && hasLoops
      ? 'MDAL은 돌고 있지만 장기 목표 파이프라인은 비어 있습니다'
      : hasGoals && !hasLoops
        ? '장기 목표는 등록되어 있고 MDAL은 아직 시작되지 않았습니다'
        : '장기 목표와 MDAL 상태를 함께 추적합니다'
  const planStatusBody = onlyBacklogActive
    ? '태스크는 execution projection에서 정상적으로 들어오고 있습니다. 반면 장기 목표와 MDAL은 자동 생성되지 않으므로, 별도로 등록하거나 시작해야 이 화면에 표시됩니다.'
    : !hasGoals && hasLoops
      ? '현재 루프는 수동으로 시작되었지만, 장기 목표 파이프라인은 아직 비어 있습니다. 중장기 구조화가 필요하면 goal을 먼저 등록하는 편이 낫습니다.'
      : hasGoals && !hasLoops
        ? '장기 목표는 등록되어 있지만 숫자 메트릭을 반복 추적하는 루프는 없습니다. MDAL은 opt-in 기능이므로 명시적으로 시작해야 합니다.'
        : 'backlog, 장기 목표, MDAL이 각각 다른 데이터 소스에서 들어옵니다. 지금 화면은 세 흐름을 한 번에 보여 주는 조감도입니다.'

  return html`
    <div class="flex flex-col gap-6">
      <section class="rounded-2xl border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-[760px]">
            <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-text-muted">Planning Status</div>
            <h3 class="mt-2 text-[22px] font-semibold tracking-[-0.02em] text-text-strong">${planStatusHeadline}</h3>
            <p class="mt-2 text-[13px] leading-relaxed text-text-muted">${planStatusBody}</p>
          </div>
          <${ActionButton}
            variant="ghost"
            size="md"
            disabled=${goalsLoading.value || mdalLoading.value}
            onClick=${() => {
              refreshGoals()
              refreshMdal()
            }}
          >
            ${goalsLoading.value || mdalLoading.value ? '새로고침 중...' : '계획 데이터 새로고침'}
          <//>
        </div>

        <div class="mt-5 grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-3">
          <${PlanningStat} label="전체 태스크" value=${totalTasks} />
          <${PlanningStat} label="할 일" value=${todo.length} />
          <${PlanningStat} label="진행 중" value=${inProgress.length} tone="warn" />
          <${PlanningStat} label="완료" value=${done.length} tone="ok" />
          <${PlanningStat} label="높은 우선순위" value=${highPriority} tone=${highPriority > 0 ? 'bad' : 'default'} />
        </div>

        <div class="mt-5 grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_repeat(2,minmax(0,1fr))]">
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
              ? '등록된 목표를 단기/중기/장기로 나눠 추적합니다. 목표가 있어야 파이프라인이 살아 있는지 판단할 수 있습니다.'
              : '현재 등록된 goal이 없습니다. goal은 자동으로 생기지 않으므로 명시적으로 upsert해야 합니다.'}
            command="masc_goal_upsert(...)"
            docHref=${COMMAND_PLANE_DOC_URL}
            docLabel="Command Plane Runbook"
          />

          <${GuideCard}
            eyebrow="MDAL"
            title="Metric-Driven Agent Loop"
            count=${loops.length}
            summary=${hasLoops
              ? '실행 중인 루프가 있으면 여기서 기준값, 현재값, 반복 이력을 바로 확인할 수 있습니다.'
              : 'MDAL은 기본 자동 시작이 아닙니다. 숫자 메트릭과 목표 조건을 정한 뒤 수동으로 시작해야 표시됩니다.'}
            command="metric_fn + goal + target을 정한 뒤 새 루프 시작"
            docHref=${MDAL_DOC_URL}
            docLabel="MDAL 상태 문서"
          >
            ${!hasLoops ? html`<${MdalStartFormButton} />` : null}
          <//>
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
              단기/중기/장기 목표를 메트릭 기준으로 구조화해 보여 줍니다. 여기는 backlog와 별도이며,
              <code class="rounded bg-white/5 px-1 py-0.5 text-[11px] text-text-strong">masc_goal_upsert</code>로 등록한 목표만 노출됩니다.
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
                backlog 태스크와 goal pipeline은 서로 다릅니다. 장기 계획이 필요하면
                <code class="mx-1 rounded bg-white/5 px-1 py-0.5 text-[11px] text-text-strong">masc_goal_upsert(...)</code>
                로 먼저 등록해야 합니다.
              </div>
              <div class="mt-3 flex flex-wrap gap-2">
                <${ExternalDocLink} href=${COMMAND_PLANE_DOC_URL} label="goal 등록 가이드" />
              </div>
            </div>
          `}
        </div>
      </details>

      <details class="overview-section-collapsible group overflow-hidden rounded-xl border border-card-border/60 bg-[rgba(9,14,24,0.82)]" open=${true}>
        <summary class="flex items-center gap-3 border-b border-card-border/60 px-4 py-3.5 cursor-pointer text-[14px] font-bold text-text-strong transition-colors hover:bg-white/3">
          <div class="min-w-0">
            <div>MDAL 루프</div>
            <div class="mt-1 text-[12px] font-normal text-text-muted">
              opt-in 기능입니다. metric 없이 자동으로 생기지 않습니다.
            </div>
          </div>
          <span class="ml-auto inline-flex items-center gap-2">
            <button type="button"
              class="rounded-lg border border-accent/35 bg-accent/10 px-2.5 py-1 text-[11px] font-medium text-accent transition-colors hover:bg-accent/16"
              onClick=${(e: Event) => { e.preventDefault(); showMdalStartForm.value = true }}
            >새 루프</button>
            <span class="inline-flex items-center rounded-lg border border-card-border/70 bg-white/4 px-2.5 py-1 text-[10px] uppercase tracking-wider text-text-body font-semibold">${loops.length}</span>
          </span>
        </summary>
        <div class="p-5">
          <div class="mb-4 text-[12px] leading-relaxed text-text-muted">
            숫자 메트릭(coverage, SSIM 등)을 반복 측정하는 루프입니다. <strong class="text-text-strong">자동 시작되지 않으며</strong>,
            profile, metric, goal을 정한 뒤 명시적으로 시작해야 이 섹션에 나타납니다.
          </div>
          ${mdalLoading.value && loops.length === 0
            ? html`<${LoadingState}>MDAL 루프 불러오는 중...<//>`
            : loops.length === 0 && (mdalState === 'error' || lastMdalError.value)
              ? html`<div class="rounded-xl border border-bad/30 bg-bad/10 p-4 text-[13px] font-medium text-bad">MDAL 스냅샷을 불러오지 못했습니다${lastMdalError.value ? `: ${lastMdalError.value}` : ''}. 백엔드 상태를 확인하세요.</div>`
              : loops.length === 0
                ? html`
                    <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-4">
                      <div class="text-[14px] font-semibold text-text-strong">가동 중인 루프가 없습니다</div>
                      <div class="mt-2 text-[13px] leading-relaxed text-text-muted">
                        MDAL은 metric이 정해진 반복 작업에서만 쓰는 기능입니다. 메트릭과 목표 조건이 준비되지 않았다면 일반 backlog task가 더 적합합니다.
                      </div>
                      <div class="mt-3 flex flex-wrap gap-2">
                        <${MdalStartFormButton} />
                        <${ExternalDocLink} href=${MDAL_DOC_URL} label="MDAL 문서" />
                      </div>
                    </div>
                  `
                : html`
                  <div class="grid gap-3">
                    ${loops.map(loop => html`<${LoopRow} key=${loop.loop_id} loop=${loop} />`)}
                  </div>
                `}
          <${MdalStartFormDialog} />
        </div>
      </details>
    </div>
  `
}
