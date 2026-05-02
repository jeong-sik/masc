// Autoresearch Surface — Autonomous experiment loop dashboard
// Displays loop overview, keep/discard ratio, cycle history, insights, and warnings.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { isLoaded } from '../lib/async-state'
import { ActionButton } from './common/button'
import { SurfaceCard } from './common/card'
import { EmptyState } from './common/empty-state'
import { Eyebrow } from './common/eyebrow'
import { InfoCard } from './common/info-card'
import { formatElapsedCompact, formatTimestampKo, formatDelta } from '../lib/format-time'
import { statusLabel } from '../lib/status-label'
import { navigate } from '../router'
import type {
  AutoresearchLoopSummary,
  AutoresearchCycleRecord,
} from '../api'

// --- State (re-exported for backward compatibility) ---

import {
  loopsResource,
  selectedLoopId,
  loopDetail,
  detailLoading,
  detailError,
  loopActionBusy,
  loopActionError,
  selectedLoop,
  authorFilter,
  filteredLoops,
  availableAuthors,
  hasMoreLoops,
  loadMoreLoops,
  loadLoops,
  refreshAutoresearchSurface,
  selectLoop,
  retrySelectedLoop,
  deleteSelectedLoop,
  resetAutoresearchState as _resetState,
} from './autoresearch-state'

import {
  showStartForm,
  resetStartFormFields,
  StartFormButton,
  StartAutoresearchForm,
} from './autoresearch-form'

export { refreshAutoresearchSurface } from './autoresearch-state'

export function resetAutoresearchState(): void {
  _resetState(resetStartFormFields)
  showStartForm.value = false
}

// --- Helpers ---

function MonoBody({ children }: { children: unknown }) {
  return html`<div class="text-[var(--color-fg-secondary)] text-sm font-mono">${children}</div>`
}

function statusColor(status: string): string {
  switch (status) {
    case 'running': return 'text-[var(--color-status-ok)]'
    case 'completed': return 'text-[var(--color-accent-fg)]'
    case 'stopped': return 'text-[var(--color-status-warn)]'
    case 'error': return 'text-[var(--color-status-err)]'
    default: return 'text-[var(--color-fg-muted)]'
  }
}

function decisionLabel(decision: string): string {
  return decision === 'keep' ? '유지' : '삭제'
}

/**
 * Pure filter for autoresearch cycle history rows.
 *
 * Case-insensitive substring match on `hypothesis`, the decision label
 * (both the raw `keep`/`discard` token and the Korean label `유지`/`삭제`),
 * and the `cycle` number coerced to a string so operators can locate a
 * cycle by partial hypothesis text, by keep/discard verdict, or by index.
 *
 * Empty/whitespace query returns the input reference unchanged so a
 * useMemo-wrapped consumer keeps referential equality for the non-
 * filtering path. Input is never mutated.
 */
export function filterCycles(
  cycles: readonly AutoresearchCycleRecord[],
  query: string,
): readonly AutoresearchCycleRecord[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return cycles
  return cycles.filter(cycle => {
    if (cycle.hypothesis.toLowerCase().includes(needle)) return true
    if (cycle.decision.toLowerCase().includes(needle)) return true
    if (decisionLabel(cycle.decision).includes(needle)) return true
    if (String(cycle.cycle).includes(needle)) return true
    return false
  })
}

function liveLabel(loop: Pick<AutoresearchLoopSummary, 'live'>): string {
  return loop.live ? '실시간' : '저장됨'
}

// --- Sub-components ---

function LoopSelector() {
  const loops = filteredLoops.value
  const authors = availableAuthors.value

  if (loops.length === 0 && authors.length === 0) return null

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <label class="text-2xs text-[var(--color-fg-muted)] font-medium">실행자 필터</label>
        <select
          aria-label="실행자 필터"
          class="bg-card border border-card-border text-[var(--color-fg-secondary)] text-xs rounded-[var(--r-1)] px-2 py-1 outline-none focus:border-accent"
          value=${authorFilter.value}
          onChange=${(e: Event) => {
            const target = e.target as HTMLSelectElement
            authorFilter.value = target.value
          }}
        >
          <option value="all">전체</option>
          ${authors.map(author => html`<option value=${author}>${author}</option>`)}
          <option value="unknown">알 수 없음</option>
        </select>
      </div>
      <div class="flex flex-wrap gap-2">
        ${loops.map(loop => {
          const isSelected = loop.loop_id === selectedLoopId.value
          return html`
            <${ActionButton}
              key=${loop.loop_id}
              variant=${isSelected ? 'ghost' : 'subtle'}
              size="md"
              pressed=${isSelected}
              class="text-xs"
              onClick=${() => selectLoop(loop.loop_id)}>
              <span class="${statusColor(loop.status)} mr-1">\u25CF</span>
              ${loop.loop_id.slice(0, 8)}
              <span class="ml-1 opacity-60">${statusLabel(loop.status)}</span>
              <span class="ml-1 opacity-60">${liveLabel(loop)}</span>
            <//>
          `
        })}
        ${loops.length === 0 ? html`<div class="text-[var(--color-fg-muted)] text-xs py-1.5">선택된 실행자의 루프가 없습니다.</div>` : null}
        ${hasMoreLoops.value ? html`
          <${ActionButton}
            variant="ghost"
            size="md"
            onClick=${() => { void loadMoreLoops() }}>
            더 불러오기
          <//>
        ` : null}
      </div>
    </div>
  `
}

function LoopOverview({ loop }: { loop: AutoresearchLoopSummary }) {
  const totalCycles = loop.total_keeps + loop.total_discards
  const keepPct = totalCycles > 0 ? ((loop.total_keeps / totalCycles) * 100).toFixed(1) : '0'

  return html`
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <div class="flex flex-col gap-3">
        <div>
          <${Eyebrow} class="mb-1">목표</${Eyebrow}>
          <div class="text-[var(--color-fg-secondary)] text-sm leading-relaxed">${loop.goal}</div>
        </div>
        <div class="grid grid-cols-2 gap-3">
          <div>
            <${Eyebrow} class="mb-0.5">상태</${Eyebrow}>
            <div class="text-sm font-medium ${statusColor(loop.status)}">${statusLabel(loop.status)}</div>
          </div>
          <div>
            <${Eyebrow} class="mb-0.5">사이클</${Eyebrow}>
            <div class="text-[var(--color-fg-primary)] text-sm font-mono">${loop.current_cycle} / ${loop.max_cycles}</div>
          </div>
          <div>
            <${Eyebrow} class="mb-0.5">경과 시간</${Eyebrow}>
            <${MonoBody}>${formatElapsedCompact(loop.elapsed_s)}</${MonoBody}>
          </div>
          <div>
            <${Eyebrow} class="mb-0.5">실행자</${Eyebrow}>
            <${MonoBody}>${loop.author ?? '알 수 없음'}</${MonoBody}>
          </div>
          <div>
            <${Eyebrow} class="mb-0.5">모델</${Eyebrow}>
            <${MonoBody}>${loop.model_model}</${MonoBody}>
          </div>
          <div>
            <${Eyebrow} class="mb-0.5">소스</${Eyebrow}>
            <div class="text-[var(--color-fg-secondary)] text-sm">${liveLabel(loop)}</div>
          </div>
          <div>
            <${Eyebrow} class="mb-0.5">최근 갱신</${Eyebrow}>
            <${MonoBody}>${loop.updated_at != null ? formatTimestampKo(loop.updated_at) : '알 수 없음'}</${MonoBody}>
          </div>
        </div>
      </div>

      <div class="flex flex-col gap-3">
        <div class="grid grid-cols-2 gap-3">
          <div>
            <${Eyebrow} class="mb-0.5">기준선</${Eyebrow}>
            <${MonoBody}>${loop.baseline.toFixed(4)}</${MonoBody}>
          </div>
          <div>
            <${Eyebrow} class="mb-0.5">최고 점수</${Eyebrow}>
            <div class="text-[var(--color-status-ok)] text-sm font-mono font-semibold">${loop.best_score.toFixed(4)}</div>
          </div>
        </div>
        <div>
          <${Eyebrow} class="mb-1">유지 / 삭제</${Eyebrow}>
          <div class="flex items-center gap-2">
            <span class="text-[var(--color-status-ok)] text-sm font-mono font-semibold">${loop.total_keeps}</span>
            <span class="text-[var(--color-fg-muted)] text-xs">/</span>
            <span class="text-[var(--color-status-err)] text-sm font-mono font-semibold">${loop.total_discards}</span>
            <span class="text-[var(--color-fg-muted)] text-xs ml-1">(${keepPct}% keep)</span>
          </div>
          ${totalCycles > 0 ? html`
            <div class="mt-1.5 h-2 rounded-[var(--r-0)] bg-[var(--white-6)] overflow-hidden flex">
              <div
                class="h-full bg-[var(--ok-48)] transition-[width] duration-300"
                style=${{ width: `${(loop.total_keeps / totalCycles) * 100}%` }}
              />
              <div
                class="h-full bg-[var(--bad-30)] transition-[width] duration-300"
                style=${{ width: `${(loop.total_discards / totalCycles) * 100}%` }}
              />
            </div>
          ` : null}
        </div>
        <div>
          <${Eyebrow} class="mb-0.5">대상 파일</${Eyebrow}>
          <div class="text-[var(--color-fg-secondary)] text-xs font-mono truncate" title=${loop.target_file}>${loop.target_file}</div>
        </div>
        <div>
          <${Eyebrow} class="mb-0.5">메트릭</${Eyebrow}>
          <div class="text-[var(--color-fg-secondary)] text-xs font-mono truncate" title=${loop.metric_fn}>${loop.metric_fn}</div>
        </div>
      </div>
    </div>

    ${loop.error ? html`
      <div class="mt-3 px-3 py-2 rounded-[var(--r-1)] bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--color-status-err)] text-xs">
        ${loop.error}
      </div>
    ` : null}
  `
}

function CycleHistoryTable({ cycles }: { cycles: AutoresearchCycleRecord[] }) {
  const query = useSignal('')
  const visibleCycles = useMemo(
    () => filterCycles(cycles, query.value),
    [cycles, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  if (cycles.length === 0) {
    return html`<${EmptyState} message="사이클 기록이 없습니다." compact />`
  }

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-end">
        <input
          type="search"
          value=${query.value}
          placeholder="가설 / 판정 / # 필터"
          aria-label="사이클 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="min-w-40 max-w-60 flex-1 rounded-[var(--r-1)] border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--color-fg-secondary)] placeholder:text-[var(--color-fg-disabled)] focus:outline-none focus:border-[var(--color-accent-fg)]"
        />
      </div>
      ${isFiltering && visibleCycles.length === 0
        ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${cycles.length} cycles)</div>`
        : html`
          <div class="overflow-x-auto overflow-y-auto max-h-100 custom-scrollbar rounded-[var(--r-1)] border border-[var(--white-6)] bg-[var(--white-3)]">
            <table class="w-full text-xs" aria-label="자율 연구 사이클 목록">
              <thead>
                <tr class="text-[var(--color-fg-muted)] text-3xs uppercase tracking-wider border-b border-[var(--white-10)]">
                  <th scope="col" class="sticky top-0 z-10 bg-[var(--color-bg-surface)] backdrop-blur-sm text-left py-2.5 px-3 font-medium">#</th>
                  <th scope="col" class="sticky top-0 z-10 bg-[var(--color-bg-surface)] backdrop-blur-sm text-left py-2.5 px-3 font-medium">가설</th>
                  <th scope="col" class="sticky top-0 z-10 bg-[var(--color-bg-surface)] backdrop-blur-sm text-right py-2.5 px-3 font-medium">이전</th>
                  <th scope="col" class="sticky top-0 z-10 bg-[var(--color-bg-surface)] backdrop-blur-sm text-right py-2.5 px-3 font-medium">이후</th>
                  <th scope="col" class="sticky top-0 z-10 bg-[var(--color-bg-surface)] backdrop-blur-sm text-right py-2.5 px-3 font-medium">변화</th>
                  <th scope="col" class="sticky top-0 z-10 bg-[var(--color-bg-surface)] backdrop-blur-sm text-center py-2.5 px-3 font-medium">판정</th>
                  <th scope="col" class="sticky top-0 z-10 bg-[var(--color-bg-surface)] backdrop-blur-sm text-right py-2.5 px-3 font-medium shadow-[1px_1px_2px_var(--black-20)]">시간</th>
                </tr>
              </thead>
              <tbody>
                ${visibleCycles.map(c => html`
                  <tr key=${c.cycle} class="border-b border-[var(--white-5)] hover:bg-[var(--white-4)] transition-colors duration-150">
                    <td class="py-2 px-3 font-mono text-[var(--color-fg-muted)]">${c.cycle}</td>
                    <td class="py-2 px-3 text-[var(--color-fg-secondary)] max-w-50 truncate" title=${c.hypothesis}>${c.hypothesis}</td>
                    <td class="py-2 px-3 text-right font-mono text-[var(--color-fg-secondary)]">${c.score_before.toFixed(4)}</td>
                    <td class="py-2 px-3 text-right font-mono text-[var(--color-fg-secondary)]">${c.score_after.toFixed(4)}</td>
                    <td class="py-2 px-3 text-right font-mono ${c.delta >= 0 ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-err)]'}">${formatDelta(c.delta)}</td>
                    <td class="py-2 px-3 text-center">
                      <span class="px-1.5 py-0.5 rounded-[var(--r-1)] text-3xs font-semibold ${
                        c.decision === 'keep'
                          ? 'bg-[var(--ok-soft)] text-[var(--color-status-ok)] border border-[var(--ok-20)]'
                          : 'bg-[var(--bad-soft)] text-[var(--color-status-err)] border border-[var(--bad-20)]'
                      }">${decisionLabel(c.decision)}</span>
                    </td>
                    <td class="py-2 px-3 text-right text-[var(--color-fg-muted)] font-mono">${formatTimestampKo(c.timestamp)}</td>
                  </tr>
                `)}
              </tbody>
            </table>
          </div>
        `}
    </div>
  `
}

function InsightsList({ insights }: { insights: string[] }) {
  if (insights.length === 0) {
    return html`<${EmptyState} message="아직 축적된 인사이트가 없습니다." compact />`
  }

  return html`
    <ul class="flex flex-col gap-1.5">
      ${insights.map((insight, i) => html`
        <li key=${i} class="flex items-start gap-2 text-xs text-[var(--color-fg-secondary)]">
          <span class="text-[var(--color-fg-muted)] mt-0.5 shrink-0">${i + 1}.</span>
          <span class="leading-relaxed">${insight}</span>
        </li>
      `)}
    </ul>
  `
}

function WarningsList({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null

  return html`
    <div class="flex flex-col gap-1.5">
      ${warnings.map((w, i) => html`
        <div key=${i} class="px-3 py-1.5 rounded-[var(--r-1)] bg-[var(--warn-10)] border border-[var(--warn-20)] text-[var(--color-status-warn)] text-xs">
          ${w}
        </div>
      `)}
    </div>
  `
}

function ResearchBrief({ loop }: { loop: AutoresearchLoopSummary }) {
  const linkedAt = loop.linked_at != null ? formatTimestampKo(loop.linked_at) : '미연결'

  return html`
    <${SurfaceCard} variant="compact">
      <div class="flex flex-col gap-3">
        <div>
          <${Eyebrow} class="mb-1 font-medium">연구 브리프</${Eyebrow}>
          <div class="text-sm leading-paragraph text-[var(--color-fg-secondary)]">
            이 루프는 <span class="font-semibold text-[var(--color-fg-primary)]">${loop.goal}</span> 를 목표로
            <span class="font-mono text-[var(--color-fg-primary)]"> ${loop.target_file} </span>
            변경을 시도하고,
            <span class="font-mono text-[var(--color-fg-primary)]"> ${loop.metric_fn} </span>
            결과로 keep/discard를 반복합니다.
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-3 text-xs">
          <${InfoCard}>
            <${Eyebrow} class="mb-1">무엇을 연구하나</${Eyebrow}>
            <div class="leading-relaxed text-[var(--color-fg-secondary)]">${loop.goal}</div>
          </${InfoCard}>
          <${InfoCard}>
            <${Eyebrow} class="mb-1">무엇으로 성공을 보나</${Eyebrow}>
            <div class="font-mono text-[var(--color-fg-secondary)]">${loop.metric_fn}</div>
            <div class="mt-1 text-[var(--color-fg-disabled)]">baseline ${loop.baseline.toFixed(4)} -> best ${loop.best_score.toFixed(4)}</div>
          </${InfoCard}>
          <${InfoCard}>
            <${Eyebrow} class="mb-1">연결된 실행 컨텍스트</${Eyebrow}>
            <div class="flex flex-col gap-1 text-[var(--color-fg-secondary)]">
              <span>session ${loop.session_id ?? '없음'}</span>
              <span>operation ${loop.operation_id ?? '없음'}</span>
              <span>linked ${linkedAt}</span>
            </div>
          </${InfoCard}>
          <${InfoCard}>
            <${Eyebrow} class="mb-1">현재 가설 / 메모</${Eyebrow}>
            <div class="flex flex-col gap-1 text-[var(--color-fg-secondary)] leading-relaxed">
              <span>${loop.queued_hypothesis ?? '대기 가설 없음'}</span>
              <span class="text-[var(--color-fg-disabled)]">${loop.program_note ?? 'program note 없음'}</span>
            </div>
          </${InfoCard}>
        </div>

        <div class="rounded-[var(--r-1)] border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-xs leading-normal text-[var(--color-fg-muted)]">
          이 화면은 generator loop 자체를 설명합니다. Safety Harness는 evaluator와 장기 실행 safety rail을 보여주며,
          각 cycle의 keep/discard 판정을 직접 대체하지 않습니다.
        </div>
      </div>
    <//>
  `
}

function OutcomeVsHarnessCallout({ loopCount }: { loopCount: number }) {
  return html`
    <${SurfaceCard} variant="compact">
      <div class="grid grid-cols-1 gap-3 md:grid-cols-[1.3fr_1fr]">
        <${InfoCard}>
          <${Eyebrow}>실험 결과</${Eyebrow}>
          <div class="mt-1 text-sm font-medium text-[var(--color-fg-primary)]">이 화면은 keep/discard 루프를 봅니다.</div>
          <div class="mt-2 text-sm leading-loose text-[var(--color-fg-secondary)]">
            어떤 파일을 바꾸고 어떤 metric을 밀어 올리려는지, 그리고 현재 ${loopCount}개 루프가 어떤 cycle에 있는지 직접 봅니다.
          </div>
        </${InfoCard}>

        <div class="rounded-[var(--r-1)] border border-[var(--white-8)] bg-[var(--white-3)] p-3">
          <${Eyebrow}>안전 하네스</${Eyebrow}>
          <div class="mt-1 text-sm font-medium text-[var(--color-fg-primary)]">심판 기계의 건강도는 별도로 봅니다.</div>
          <div class="mt-2 text-sm leading-loose text-[var(--color-fg-secondary)]">
            평가 모델, 압축 전 상태, 세대 교체 rail 상태는 하네스에서 봅니다.
          </div>
          <${ActionButton}
            variant="ghost"
            size="sm"
            class="mt-3"
            onClick=${() => navigate('lab', { section: 'harness' })}
          >하네스 열기<//>
        </div>
      </div>
    <//>
  `
}

// --- Detail view ---

function LoopDetailView() {
  const loop = selectedLoop.value
  const detail = loopDetail.value

  if (!loop) {
    return html`<${EmptyState} message="루프를 선택하면 상세 내용이 표시됩니다." compact />`
  }

  if (detailLoading.value) {
    return html`<${EmptyState} message="상세 정보를 불러오는 중..." compact />`
  }

  if (detailError.value) {
    return html`
      <div class="px-3 py-2 rounded-[var(--r-1)] bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--color-status-err)] text-xs">
        ${detailError.value}
      </div>
    `
  }

  const cycles = detail?.history ?? loop.recent_cycles ?? []
  const insights = detail?.insights ?? loop.insights ?? []
  const warnings = loop.warnings ?? []
  const canRepairErrorLoop = loop.status === 'error'

  return html`
    <div class="flex flex-col gap-5">
      <${ResearchBrief} loop=${loop} />

      <${SurfaceCard} variant="compact">
        <div class="flex items-start justify-between gap-3 mb-3">
          <${Eyebrow} class="font-medium">루프 개요</${Eyebrow}>
          ${canRepairErrorLoop ? html`
            <div class="flex items-center gap-2">
              <${ActionButton}
                variant="ghost"
                size="sm"
                disabled=${loopActionBusy.value}
                ariaBusy=${loopActionBusy.value}
                onClick=${() => { void retrySelectedLoop() }}
              >
                ${loopActionBusy.value ? '복구 중...' : '재시도'}
              <//>
              <${ActionButton}
                variant="danger"
                size="sm"
                disabled=${loopActionBusy.value}
                onClick=${() => { void deleteSelectedLoop() }}
              >
                삭제
              <//>
            </div>
          ` : null}
        </div>
        <${LoopOverview} loop=${loop} />
        ${loopActionError.value ? html`
          <div class="mt-3 px-3 py-2 rounded-[var(--r-1)] bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--color-status-err)] text-xs">
            ${loopActionError.value}
          </div>
        ` : null}
      <//>

      ${warnings.length > 0 ? html`
        <${SurfaceCard} variant="compact">
          <div class="text-3xs uppercase tracking-wider text-[var(--color-status-warn)]/80 mb-3 font-medium">경고</div>
          <${WarningsList} warnings=${warnings} />
        <//>
      ` : null}

      <${SurfaceCard} variant="compact">
        <div class="flex items-center justify-between mb-3">
          <${Eyebrow} class="font-medium">
            사이클 이력 ${detail ? `(${detail.history_count}건)` : ''}
          </${Eyebrow}>
        </div>
        <${CycleHistoryTable} cycles=${cycles} />
      <//>

      <${SurfaceCard} variant="compact">
        <${Eyebrow} class="mb-3 font-medium">인사이트</${Eyebrow}>
        <${InsightsList} insights=${insights} />
      <//>
    </div>
  `
}

// --- Main component ---

export function Autoresearch() {
  useEffect(() => {
    void refreshAutoresearchSurface()
  }, [])

  const state = loopsResource.state.value
  const isFirstLoad = state.status === 'loading' || state.status === 'idle'

  if (isFirstLoad) {
    return html`<${EmptyState} message="오토리서치 루프 데이터를 불러오는 중..." />`
  }

  if (state.status === 'error') {
    return html`
      <div class="flex flex-col gap-4">
        <div class="px-4 py-3 rounded-[var(--r-1)] bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--color-status-err)] text-sm">
          ${state.message}
        </div>
        <${ActionButton}
          variant="ghost"
          size="md"
          class="self-start"
          onClick=${() => loadLoops()}
        >
          다시 시도
        <//>
      </div>
    `
  }

  const loops = isLoaded(state) ? state.data.loops : []

  if (loops.length === 0) {
    return html`
      <div class="flex flex-col gap-4">
        <${EmptyState}
          message="실행된 오토리서치 루프가 없습니다."
          icon="🔬"
          action=${html`<${StartFormButton} />`}
        />
        ${showStartForm.value ? html`<${StartAutoresearchForm} />` : null}
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-5">
      <${OutcomeVsHarnessCallout} loopCount=${loops.length} />

      <div class="flex items-center justify-between">
        <${Eyebrow} class="font-medium">
          전체 ${loops.length}개 루프
        </${Eyebrow}>
        <div class="flex items-center gap-2">
          <${StartFormButton}
            class="px-2.5 py-1 rounded-[var(--r-1)] text-2xs text-accent border border-accent/40 hover:bg-[var(--accent-10)] transition-colors"
          />
          <a href="/api/v1/autoresearch/loops/csv" download="autoresearch_loops.csv"
            class="px-2.5 py-1 rounded-[var(--r-1)] text-2xs text-[var(--color-fg-muted)] border border-card-border hover:text-[var(--color-fg-secondary)] hover:border-accent/40 transition-colors no-underline"
          >
            CSV 다운로드
          </a>
          <${ActionButton}
            variant="ghost"
            size="sm"
            onClick=${() => { void refreshAutoresearchSurface() }}
          >
            새로고침
          <//>
        </div>
      </div>

      <${LoopSelector} />
      <${LoopDetailView} />
      ${showStartForm.value ? html`<${StartAutoresearchForm} />` : null}
    </div>
  `
}
