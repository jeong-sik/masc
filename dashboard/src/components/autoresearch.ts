// Autoresearch Surface — Autonomous experiment loop dashboard
// Displays loop overview, keep/discard ratio, cycle history, insights, and warnings.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { isLoaded } from '../lib/async-state'
import { SurfaceCard } from './common/card'
import { EmptyState } from './common/empty-state'
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

function statusColor(status: string): string {
  switch (status) {
    case 'running': return 'text-[var(--ok)]'
    case 'completed': return 'text-[var(--accent)]'
    case 'stopped': return 'text-[var(--warn)]'
    case 'error': return 'text-[var(--bad)]'
    default: return 'text-[var(--text-muted)]'
  }
}

function decisionLabel(decision: string): string {
  return decision === 'keep' ? '유지' : '삭제'
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
        <label class="text-[11px] text-[var(--text-muted)] font-medium">실행자 필터</label>
        <select
          class="bg-card border border-card-border text-[var(--text-body)] text-xs rounded px-2 py-1 outline-none focus:border-accent"
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
          const cls = isSelected
            ? 'px-3 py-1.5 rounded-lg text-xs font-medium border border-accent/60 bg-[var(--accent-10)] text-[var(--text-strong)] cursor-pointer'
            : 'px-3 py-1.5 rounded-lg text-xs font-medium border border-card-border bg-card/60 text-[var(--text-muted)] cursor-pointer hover:border-accent/30 transition-colors'
          return html`
            <button type="button" key=${loop.loop_id} class=${cls} onClick=${() => selectLoop(loop.loop_id)}>
              <span class="${statusColor(loop.status)} mr-1">\u25CF</span>
              ${loop.loop_id.slice(0, 8)}
              <span class="ml-1 opacity-60">${statusLabel(loop.status)}</span>
              <span class="ml-1 opacity-60">${liveLabel(loop)}</span>
            </button>
          `
        })}
        ${loops.length === 0 ? html`<div class="text-[var(--text-muted)] text-xs py-1.5">선택된 실행자의 루프가 없습니다.</div>` : null}
        ${hasMoreLoops.value ? html`
          <button type="button" 
            class="px-3 py-1.5 rounded-lg text-xs font-medium border border-card-border bg-card/60 text-accent cursor-pointer hover:bg-[var(--accent-10)] hover:border-accent/40 transition-colors flex items-center gap-1" 
            onClick=${() => { void loadMoreLoops() }}>
            <span>더 불러오기</span>
          </button>
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
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-1">목표</div>
          <div class="text-[var(--text-body)] text-sm leading-relaxed">${loop.goal}</div>
        </div>
        <div class="grid grid-cols-2 gap-3">
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">상태</div>
            <div class="text-sm font-medium ${statusColor(loop.status)}">${statusLabel(loop.status)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">사이클</div>
            <div class="text-[var(--text-strong)] text-sm font-mono">${loop.current_cycle} / ${loop.max_cycles}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">경과 시간</div>
            <div class="text-[var(--text-body)] text-sm font-mono">${formatElapsedCompact(loop.elapsed_s)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">실행자</div>
            <div class="text-[var(--text-body)] text-sm font-mono">${loop.author ?? '알 수 없음'}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">모델</div>
            <div class="text-[var(--text-body)] text-sm font-mono">${loop.model_model}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">소스</div>
            <div class="text-[var(--text-body)] text-sm">${liveLabel(loop)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">최근 갱신</div>
            <div class="text-[var(--text-body)] text-sm font-mono">${loop.updated_at != null ? formatTimestampKo(loop.updated_at) : '알 수 없음'}</div>
          </div>
        </div>
      </div>

      <div class="flex flex-col gap-3">
        <div class="grid grid-cols-2 gap-3">
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">기준선</div>
            <div class="text-[var(--text-body)] text-sm font-mono">${loop.baseline.toFixed(4)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">최고 점수</div>
            <div class="text-[var(--ok)] text-sm font-mono font-semibold">${loop.best_score.toFixed(4)}</div>
          </div>
        </div>
        <div>
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-1">유지 / 삭제</div>
          <div class="flex items-center gap-2">
            <span class="text-[var(--ok)] text-sm font-mono font-semibold">${loop.total_keeps}</span>
            <span class="text-[var(--text-muted)] text-xs">/</span>
            <span class="text-[var(--bad)] text-sm font-mono font-semibold">${loop.total_discards}</span>
            <span class="text-[var(--text-muted)] text-xs ml-1">(${keepPct}% keep)</span>
          </div>
          ${totalCycles > 0 ? html`
            <div class="mt-1.5 h-2 rounded-full bg-[var(--white-6)] overflow-hidden flex">
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
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">대상 파일</div>
          <div class="text-[var(--text-body)] text-xs font-mono truncate" title=${loop.target_file}>${loop.target_file}</div>
        </div>
        <div>
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">메트릭</div>
          <div class="text-[var(--text-body)] text-xs font-mono truncate" title=${loop.metric_fn}>${loop.metric_fn}</div>
        </div>
      </div>
    </div>

    ${loop.error ? html`
      <div class="mt-3 px-3 py-2 rounded-lg bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--bad)] text-xs">
        ${loop.error}
      </div>
    ` : null}
  `
}

function CycleHistoryTable({ cycles }: { cycles: AutoresearchCycleRecord[] }) {
  if (cycles.length === 0) {
    return html`<${EmptyState} message="사이클 기록이 없습니다." compact />`
  }

  return html`
    <div class="overflow-x-auto overflow-y-auto max-h-[400px] custom-scrollbar rounded-lg border border-[var(--white-6)] bg-[rgba(0,0,0,0.1)]">
      <table class="w-full text-xs">
        <thead>
          <tr class="text-[var(--text-muted)] text-[10px] uppercase tracking-wider border-b border-[var(--white-10)]">
            <th scope="col" class="sticky top-0 z-10 bg-[rgba(10,18,34,0.95)] backdrop-blur-md text-left py-2.5 px-3 font-medium">#</th>
            <th scope="col" class="sticky top-0 z-10 bg-[rgba(10,18,34,0.95)] backdrop-blur-md text-left py-2.5 px-3 font-medium">가설</th>
            <th scope="col" class="sticky top-0 z-10 bg-[rgba(10,18,34,0.95)] backdrop-blur-md text-right py-2.5 px-3 font-medium">이전</th>
            <th scope="col" class="sticky top-0 z-10 bg-[rgba(10,18,34,0.95)] backdrop-blur-md text-right py-2.5 px-3 font-medium">이후</th>
            <th scope="col" class="sticky top-0 z-10 bg-[rgba(10,18,34,0.95)] backdrop-blur-md text-right py-2.5 px-3 font-medium">변화</th>
            <th scope="col" class="sticky top-0 z-10 bg-[rgba(10,18,34,0.95)] backdrop-blur-md text-center py-2.5 px-3 font-medium">판정</th>
            <th scope="col" class="sticky top-0 z-10 bg-[rgba(10,18,34,0.95)] backdrop-blur-md text-right py-2.5 px-3 font-medium shadow-[1px_1px_2px_rgba(0,0,0,0.2)]">시간</th>
          </tr>
        </thead>
        <tbody>
          ${cycles.map(c => html`
            <tr key=${c.cycle} class="border-b border-[var(--white-5)] hover:bg-[var(--white-4)] transition-colors duration-150">
              <td class="py-2 px-3 font-mono text-[var(--text-muted)]">${c.cycle}</td>
              <td class="py-2 px-3 text-[var(--text-body)] max-w-[200px] truncate" title=${c.hypothesis}>${c.hypothesis}</td>
              <td class="py-2 px-3 text-right font-mono text-[var(--text-body)]">${c.score_before.toFixed(4)}</td>
              <td class="py-2 px-3 text-right font-mono text-[var(--text-body)]">${c.score_after.toFixed(4)}</td>
              <td class="py-2 px-3 text-right font-mono ${c.delta >= 0 ? 'text-[var(--ok)]' : 'text-[var(--bad)]'}">${formatDelta(c.delta)}</td>
              <td class="py-2 px-3 text-center">
                <span class="px-1.5 py-0.5 rounded text-[10px] font-semibold ${
                  c.decision === 'keep'
                    ? 'bg-[var(--ok-soft)] text-[var(--ok)] border border-[var(--ok-20)]'
                    : 'bg-[var(--bad-soft)] text-[var(--bad)] border border-[var(--bad-20)]'
                }">${decisionLabel(c.decision)}</span>
              </td>
              <td class="py-2 px-3 text-right text-[var(--text-muted)] font-mono">${formatTimestampKo(c.timestamp)}</td>
            </tr>
          `)}
        </tbody>
      </table>
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
        <li key=${i} class="flex items-start gap-2 text-xs text-[var(--text-body)]">
          <span class="text-[var(--text-muted)] mt-0.5 shrink-0">${i + 1}.</span>
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
        <div key=${i} class="px-3 py-1.5 rounded-lg bg-[var(--warn-10)] border border-[var(--warn-20)] text-[var(--warn)] text-xs">
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
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-1 font-medium">Research Brief</div>
          <div class="text-[13px] leading-[1.55] text-[var(--text-body)]">
            이 루프는 <span class="font-semibold text-[var(--text-strong)]">${loop.goal}</span> 를 목표로
            <span class="font-mono text-[var(--text-strong)]"> ${loop.target_file} </span>
            변경을 시도하고,
            <span class="font-mono text-[var(--text-strong)]"> ${loop.metric_fn} </span>
            결과로 keep/discard를 반복합니다.
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-3 text-xs">
          <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
            <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-muted)]">무엇을 연구하나</div>
            <div class="leading-relaxed text-[var(--text-body)]">${loop.goal}</div>
          </div>
          <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
            <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-muted)]">무엇으로 성공을 보나</div>
            <div class="font-mono text-[var(--text-body)]">${loop.metric_fn}</div>
            <div class="mt-1 text-[var(--text-dim)]">baseline ${loop.baseline.toFixed(4)} -> best ${loop.best_score.toFixed(4)}</div>
          </div>
          <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
            <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-muted)]">연결된 실행 컨텍스트</div>
            <div class="flex flex-col gap-1 text-[var(--text-body)]">
              <span>session ${loop.session_id ?? '없음'}</span>
              <span>operation ${loop.operation_id ?? '없음'}</span>
              <span>linked ${linkedAt}</span>
            </div>
          </div>
          <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
            <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-muted)]">현재 가설 / 메모</div>
            <div class="flex flex-col gap-1 text-[var(--text-body)] leading-relaxed">
              <span>${loop.queued_hypothesis ?? '대기 가설 없음'}</span>
              <span class="text-[var(--text-dim)]">${loop.program_note ?? 'program note 없음'}</span>
            </div>
          </div>
        </div>

        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-[12px] leading-[1.5] text-[var(--text-muted)]">
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
        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Experiment Outcomes</div>
          <div class="mt-1 text-sm font-medium text-[var(--text-strong)]">이 화면은 keep/discard 루프를 봅니다.</div>
          <div class="mt-2 text-sm leading-[1.6] text-[var(--text-body)]">
            어떤 파일을 바꾸고 어떤 metric을 밀어 올리려는지, 그리고 현재 ${loopCount}개 루프가 어떤 cycle에 있는지 직접 봅니다.
          </div>
        </div>

        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] p-3">
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Safety Harness</div>
          <div class="mt-1 text-sm font-medium text-[var(--text-strong)]">심판 기계의 건강도는 별도로 봅니다.</div>
          <div class="mt-2 text-sm leading-[1.6] text-[var(--text-body)]">
            평가 모델, 압축 전 상태, 세대 교체 rail 상태는 하네스에서 봅니다.
          </div>
          <button
            type="button"
            class="mt-3 rounded border border-[var(--white-8)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] transition-colors hover:border-[var(--ok-30)] hover:text-[var(--text-body)]"
            onClick=${() => navigate('lab', { section: 'harness' })}
          >하네스 열기</button>
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
      <div class="px-3 py-2 rounded-lg bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--bad)] text-xs">
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
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">루프 개요</div>
          ${canRepairErrorLoop ? html`
            <div class="flex items-center gap-2">
              <button
                type="button"
                class="px-2.5 py-1 rounded text-[11px] text-[var(--text-body)] border border-card-border hover:border-accent/40 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                disabled=${loopActionBusy.value}
                onClick=${() => { void retrySelectedLoop() }}
              >
                ${loopActionBusy.value ? '복구 중...' : '재시도'}
              </button>
              <button
                type="button"
                class="px-2.5 py-1 rounded text-[11px] text-[var(--bad)] border border-[var(--bad-30)] hover:border-[var(--bad)] opacity-50 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                disabled=${loopActionBusy.value}
                onClick=${() => { void deleteSelectedLoop() }}
              >
                삭제
              </button>
            </div>
          ` : null}
        </div>
        <${LoopOverview} loop=${loop} />
        ${loopActionError.value ? html`
          <div class="mt-3 px-3 py-2 rounded-lg bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--bad)] text-xs">
            ${loopActionError.value}
          </div>
        ` : null}
      <//>

      ${warnings.length > 0 ? html`
        <${SurfaceCard} variant="compact">
          <div class="text-[10px] uppercase tracking-wider text-[var(--warn)]/80 mb-3 font-medium">경고</div>
          <${WarningsList} warnings=${warnings} />
        <//>
      ` : null}

      <${SurfaceCard} variant="compact">
        <div class="flex items-center justify-between mb-3">
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">
            사이클 이력 ${detail ? `(${detail.history_count}건)` : ''}
          </div>
        </div>
        <${CycleHistoryTable} cycles=${cycles} />
      <//>

      <${SurfaceCard} variant="compact">
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-3 font-medium">인사이트</div>
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
        <div class="px-4 py-3 rounded-lg bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--bad)] text-sm">
          ${state.message}
        </div>
        <button type="button"
          class="self-start px-3 py-1.5 rounded-lg text-xs font-medium border border-card-border text-[var(--text-muted)] hover:text-[var(--text-body)] hover:border-accent/40 transition-colors"
          onClick=${() => loadLoops()}
        >
          다시 시도
        </button>
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
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">
          전체 ${loops.length}개 루프
        </div>
        <div class="flex items-center gap-2">
          <${StartFormButton}
            class="px-2.5 py-1 rounded text-[11px] text-accent border border-accent/40 hover:bg-[var(--accent-10)] transition-colors"
          />
          <button type="button"
            class="px-2.5 py-1 rounded text-[11px] text-[var(--text-muted)] border border-card-border hover:text-[var(--text-body)] hover:border-accent/40 transition-colors"
            onClick=${() => { void refreshAutoresearchSurface() }}
          >
            새로고침
          </button>
        </div>
      </div>

      <${LoopSelector} />
      <${LoopDetailView} />
      ${showStartForm.value ? html`<${StartAutoresearchForm} />` : null}
    </div>
  `
}
