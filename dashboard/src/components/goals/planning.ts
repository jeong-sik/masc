// Planning main component — orchestrates goals and kanban views

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useMemo } from 'preact/hooks'
import { EmptyState } from '../common/empty-state'
import { ActionButton } from '../common/button'
import {
  goals,
  goalsLoading,
  refreshGoals,
  tasksByStatus,
  keepers,
} from '../../store'
import { navigate } from '../../router'
import {
  groupedByHorizon,
  horizonProgress,
  formatProgressPct,
  goalProgressFor,
  TaskProgressBar,
  horizonLabel,
  goalPhaseLabel,
} from './goal-helpers'
import { TaskBacklog } from './kanban-components'
import { TaskStaleAlert } from './task-stale-alert'
import { TaskWall } from './task-wall'
import { TaskCreateForm } from '../task-manage/task-create-form'

const QUICK_START_DOC_URL = 'https://github.com/jeong-sik/masc-mcp/blob/main/docs/QUICK-START.md'

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
    <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
      <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">${label}</div>
      <div class="mt-2 text-3xl font-bold leading-none tabular-nums ${toneClass}">${value}</div>
    </div>
  `
}

function ExternalDocLink({ href, label }: { href: string; label: string }) {
  return html`
    <a
      href=${href}
      target="_blank"
      rel="noreferrer"
      class="inline-flex items-center gap-1 rounded border border-card-border/70 bg-[var(--white-3)] px-2.5 py-1.5 text-2xs font-medium text-text-body transition-colors hover:border-accent/35 hover:text-text-strong"
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
    <section class="flex flex-col gap-3 rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label=${title}>
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">${eyebrow}</div>
          <h3 class="mt-1 text-md font-semibold text-text-strong">${title}</h3>
        </div>
        <span class="rounded border border-card-border/70 bg-[var(--white-4)] px-2.5 py-1 text-2xs font-semibold text-text-body">
          ${count}
        </span>
      </div>
      <p class="text-sm leading-relaxed text-text-muted whitespace-pre-wrap">${summary}</p>
      ${command ? html`
        <div class="rounded border border-card-border/60 bg-[var(--white-3)] px-3 py-2 text-xs leading-relaxed text-text-body">
          <code class="text-2xs text-text-strong">${command}</code>
        </div>
      ` : null}
      ${children}
      <div class="pt-1">
        <${ExternalDocLink} href=${docHref} label=${docLabel} />
      </div>
    </section>
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

  // Aggregate top tools across all keepers (memoized)
  const { topTools, totalToolTurns } = useMemo(() => {
    const toolCounts = new Map<string, number>()
    let turns = 0
    for (const k of keeperList) {
      turns += k.autonomous_tool_turn_count ?? 0
      const items = k.metrics_window?.top_tools
      if (items) {
        for (const t of items) {
          const name = t.tool ?? ''
          if (name) toolCounts.set(name, (toolCounts.get(name) ?? 0) + (t.count ?? 1))
        }
      }
    }
    return {
      topTools: [...toolCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8),
      totalToolTurns: turns,
    }
  }, [keeperList])

  return html`
    <details class="overview-section-collapsible group overflow-hidden rounded border border-card-border/60 bg-[var(--backdrop-deep)]" open=${true}>
      <summary class="flex items-center gap-3 border-b border-card-border/60 px-4 py-3.5 cursor-pointer text-base font-bold text-text-strong transition-colors hover:bg-[var(--white-3)]">
        <div class="min-w-0">
          <div>도구 활동 요약</div>
          <div class="mt-1 text-xs font-normal text-text-muted">
            keeper가 최근 사용한 도구와 활동 현황. 상세는 keeper 클릭.
          </div>
        </div>
        <span class="ml-auto inline-flex items-center rounded border border-card-border/70 bg-[var(--white-4)] px-2.5 py-1 text-3xs uppercase tracking-wider text-text-body font-semibold">
          ${totalToolTurns} calls
        </span>
      </summary>
      <div class="p-5">
        ${activeKeepers.length > 0 ? html`
          <div class="mb-4">
            <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted mb-2">활성 keeper</div>
            <div class="flex flex-wrap gap-2">
              ${activeKeepers.map(k => html`
                <button
                  key=${k.name}
                  type="button"
                  class="inline-flex items-center gap-1.5 rounded border border-card-border/60 bg-[var(--white-4)] px-3 py-1.5 text-xs text-text-body transition-colors hover:border-accent/35 hover:text-text-strong"
                  onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
                >
                  ${k.emoji ?? ''} ${k.koreanName ?? k.name}
                  <span class="text-3xs font-mono text-text-dim">${k.turn_count ?? 0}t</span>
                </button>
              `)}
            </div>
          </div>
        ` : null}

        ${topTools.length > 0 ? html`
          <div>
            <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted mb-2">최근 자주 사용된 도구</div>
            <div class="grid grid-cols-[repeat(auto-fill,minmax(200px,1fr))] gap-1.5">
              ${topTools.map(([name, count]) => html`
                <div key=${name} class="flex items-center justify-between rounded bg-[var(--white-3)] px-3 py-1.5 text-xs">
                  <span class="font-mono text-text-body truncate">${name.replace(/^(keeper_|masc_)/, '')}</span>
                  <span class="ml-2 flex-shrink-0 font-mono text-text-dim">${count}</span>
                </div>
              `)}
            </div>
          </div>
        ` : html`
          <${EmptyState} message="도구 호출 데이터가 아직 없습니다" compact />
        `}
      </div>
    </details>
  `
}

export function Planning() {
  const { todo, inProgress, done } = tasksByStatus.value
  const totalTasks = todo.length + inProgress.length + done.length
  const highPriority = [...todo, ...inProgress].filter(t => (t.priority ?? 4) <= 2).length

  const grouped = groupedByHorizon.value
  const hp = horizonProgress.value
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
      <section class="rounded border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5" aria-label="계획 상태 요약">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-190">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-text-muted">계획 상태</div>
            <h3 class="mt-2 text-[22px] font-semibold tracking-[-0.02em] text-text-strong">${planStatusHeadline}</h3>
            <p class="mt-2 text-sm leading-relaxed text-text-muted whitespace-pre-wrap">${planStatusBody}</p>
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
          <section class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="태스크 추가">
            <div class="mb-3">
              <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">백로그 항목</div>
              <h3 class="mt-1 text-md font-semibold text-text-strong">태스크 추가</h3>
            </div>
            <${TaskCreateForm} />
            <div class="mt-3 flex items-center gap-2">
              <${ExternalDocLink} href=${QUICK_START_DOC_URL} label="빠른 시작" />
            </div>
          </section>

          <${GuideCard}
            eyebrow="목표 파이프라인"
            title="장기 목표 파이프라인"
            count=${goals.value.length}
            summary=${hasGoals
              ? '등록된 목표를 단기/중기/장기로 나눠 추적합니다.'
              : '등록된 목표가 없습니다. 목표를 등록하면 여기에 표시됩니다.'}
            docHref=${QUICK_START_DOC_URL}
            docLabel="빠른 시작"
          />
        </div>
      </section>

      <${TaskStaleAlert} />

      <${TaskBacklog} />

      <${TaskWall} />

      <${KeeperToolActivity} />

      <section class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4" aria-label="목표 파이프라인">
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted">목표 파이프라인</div>
            <h3 class="mt-1 text-md font-semibold text-text-strong">
              장기 목표 ${hasGoals ? `(${goals.value.length})` : ''}
            </h3>
          </div>
          <button
            type="button"
            class="inline-flex items-center gap-1.5 rounded border border-accent/25 bg-[var(--accent-12)] px-3 py-1.5 text-xs font-medium text-accent transition-colors hover:border-accent/40 hover:bg-[var(--accent-15)]"
            onClick=${() => navigate('workspace', { section: 'planning', view: 'goal-tree' })}
          >
            목표 트리에서 보기
            <span aria-hidden="true">\u2192</span>
          </button>
        </div>
        ${hasGoals ? html`
          <div class="mt-3 flex flex-col gap-2">
            <div class="flex flex-wrap gap-2">
              ${(grouped.short ?? []).length > 0 ? html`
                <span class="rounded border border-ok/25 bg-ok/10 px-2 py-0.5 text-2xs text-ok">
                  단기 ${(grouped.short ?? []).length}${hp.short.total > 0 ? ` · ${hp.short.done}/${hp.short.total} (${formatProgressPct(hp.short)})` : ''}
                </span>
              ` : null}
              ${(grouped.mid ?? []).length > 0 ? html`
                <span class="rounded border border-warn/25 bg-warn/10 px-2 py-0.5 text-2xs text-warn">
                  중기 ${(grouped.mid ?? []).length}${hp.mid.total > 0 ? ` · ${hp.mid.done}/${hp.mid.total} (${formatProgressPct(hp.mid)})` : ''}
                </span>
              ` : null}
              ${(grouped.long ?? []).length > 0 ? html`
                <span class="rounded border border-accent/25 bg-[var(--accent-10)] px-2 py-0.5 text-2xs text-accent">
                  장기 ${(grouped.long ?? []).length}${hp.long.total > 0 ? ` · ${hp.long.done}/${hp.long.total} (${formatProgressPct(hp.long)})` : ''}
                </span>
              ` : null}
            </div>
            ${(hp.short.total + hp.mid.total + hp.long.total) > 0 ? html`
              <div class="flex flex-col gap-1">
                ${hp.short.total > 0 ? html`
                  <div class="flex items-center gap-2 text-2xs">
                    <span class="w-8 shrink-0 text-text-muted">단기</span>
                    <div
                      class="relative h-1.5 grow overflow-hidden rounded-sm bg-[var(--color-bg-surface)]"
                      role="progressbar"
                      aria-valuenow=${Math.round(hp.short.ratio * 100)}
                      aria-valuemin="0"
                      aria-valuemax="100"
                      aria-label=${`단기 목표 진행 ${hp.short.done}/${hp.short.total}`}
                    >
                      <div
                        class="absolute inset-y-0 left-0 bg-ok"
                        style=${`width: ${(hp.short.ratio * 100).toFixed(1)}%`}
                      ></div>
                    </div>
                  </div>
                ` : null}
                ${hp.mid.total > 0 ? html`
                  <div class="flex items-center gap-2 text-2xs">
                    <span class="w-8 shrink-0 text-text-muted">중기</span>
                    <div
                      class="relative h-1.5 grow overflow-hidden rounded-sm bg-[var(--color-bg-surface)]"
                      role="progressbar"
                      aria-valuenow=${Math.round(hp.mid.ratio * 100)}
                      aria-valuemin="0"
                      aria-valuemax="100"
                      aria-label=${`중기 목표 진행 ${hp.mid.done}/${hp.mid.total}`}
                    >
                      <div
                        class="absolute inset-y-0 left-0 bg-warn"
                        style=${`width: ${(hp.mid.ratio * 100).toFixed(1)}%`}
                      ></div>
                    </div>
                  </div>
                ` : null}
                ${hp.long.total > 0 ? html`
                  <div class="flex items-center gap-2 text-2xs">
                    <span class="w-8 shrink-0 text-text-muted">장기</span>
                    <div
                      class="relative h-1.5 grow overflow-hidden rounded-sm bg-[var(--color-bg-surface)]"
                      role="progressbar"
                      aria-valuenow=${Math.round(hp.long.ratio * 100)}
                      aria-valuemin="0"
                      aria-valuemax="100"
                      aria-label=${`장기 목표 진행 ${hp.long.done}/${hp.long.total}`}
                    >
                      <div
                        class="absolute inset-y-0 left-0 bg-accent"
                        style=${`width: ${(hp.long.ratio * 100).toFixed(1)}%`}
                      ></div>
                    </div>
                  </div>
                ` : null}
              </div>
            ` : null}
            <div class="mt-4 flex flex-col gap-3">
              ${(['short', 'mid', 'long'] as const).map(h => {
                const list = grouped[h] ?? []
                if (list.length === 0) return null
                return html`
                  <div key=${h}>
                    <div class="text-2xs font-semibold uppercase tracking-5 text-text-muted mb-2">
                      ${horizonLabel(h)} 목표
                    </div>
                    <div class="flex flex-col gap-2">
                      ${list.map(g => {
                        const p = goalProgressFor(g.id)
                        return html`
                          <div key=${g.id} class="flex items-center gap-3 rounded border border-card-border/60 bg-[var(--white-3)] px-3 py-2">
                            <div class="min-w-0 flex-1">
                              <div class="flex items-center gap-2">
                                <span class="text-xs font-medium text-text-strong truncate">${g.title}</span>
                                <span class="shrink-0 rounded border border-card-border/70 bg-[var(--white-4)] px-1.5 py-0.5 text-3xs text-text-muted">${goalPhaseLabel(g.phase)}</span>
                              </div>
                            </div>
                            <div class="w-28">
                              <${TaskProgressBar} done=${p.done} total=${p.total} size="sm" />
                            </div>
                          </div>
                        `
                      })}
                    </div>
                  </div>
                `
              })}
            </div>
          </div>
        ` : html`
          <p class="mt-2 text-sm text-text-muted">등록된 목표가 없습니다. 목표 트리에서 추가할 수 있습니다.</p>
        `}
      </section>
    </div>
  `
}
