// Autoresearch Surface — Autonomous experiment loop dashboard
// Displays loop overview, keep/discard ratio, cycle history, insights, and warnings.

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { SurfaceCard } from './common/card'
import { EmptyState } from './common/empty-state'
import { formatElapsedCompact } from '../lib/format-time'
import {
  deleteAutoresearchLoop,
  fetchAutoresearchLoops,
  fetchAutoresearchLoopDetail,
  retryAutoresearchLoop,
  type AutoresearchLoopsResponse,
  type AutoresearchLoopDetail,
  type AutoresearchLoopSummary,
  type AutoresearchCycleRecord,
} from '../api'

// --- State ---

const loopsData = signal<AutoresearchLoopsResponse | null>(null)
const loopsLoading = signal(false)
const loopsError = signal<string | null>(null)

const selectedLoopId = signal<string | null>(null)
const loopDetail = signal<AutoresearchLoopDetail | null>(null)
const detailLoading = signal(false)
const detailError = signal<string | null>(null)
const loopActionBusy = signal(false)
const loopActionError = signal<string | null>(null)

let loopsRequest: Promise<void> | null = null
let pendingRefreshDetail = false
let detailRequestSeq = 0

const selectedLoop = computed<AutoresearchLoopSummary | null>(() => {
  const id = selectedLoopId.value
  if (!id || !loopsData.value) return null
  return loopsData.value.loops.find(l => l.loop_id === id) ?? null
})

// --- Data loading ---

function nextSelectedLoopId(data: AutoresearchLoopsResponse): string | null {
  const currentId = selectedLoopId.value
  if (currentId && data.loops.some(loop => loop.loop_id === currentId)) {
    return currentId
  }
  return data.loops[0]?.loop_id ?? null
}

async function syncSelectedLoopDetail(data: AutoresearchLoopsResponse): Promise<void> {
  const nextLoopId = nextSelectedLoopId(data)
  selectedLoopId.value = nextLoopId
  if (!nextLoopId) {
    loopDetail.value = null
    detailError.value = null
    return
  }
  await loadDetail(nextLoopId)
}

async function loadLoops({ refreshDetail = false }: { refreshDetail?: boolean } = {}) {
  pendingRefreshDetail ||= refreshDetail
  if (loopsRequest) return loopsRequest

  loopsLoading.value = true
  loopsError.value = null
  loopsRequest = (async () => {
    try {
      const data = await fetchAutoresearchLoops()
      loopsData.value = data
      if (pendingRefreshDetail) {
        pendingRefreshDetail = false
        await syncSelectedLoopDetail(data)
      } else if (!selectedLoopId.value && data.loops.length > 0) {
        const first = data.loops[0]
        if (first) {
          selectedLoopId.value = first.loop_id
        }
      }
    } catch (err) {
      loopsError.value = err instanceof Error ? err.message : String(err)
    } finally {
      pendingRefreshDetail = false
      loopsLoading.value = false
      loopsRequest = null
    }
  })()

  return loopsRequest
}

export async function refreshAutoresearchSurface(): Promise<void> {
  await loadLoops({ refreshDetail: true })
}

async function loadDetail(loopId: string) {
  const requestSeq = ++detailRequestSeq
  detailLoading.value = true
  detailError.value = null
  try {
    const detail = await fetchAutoresearchLoopDetail(loopId)
    if (requestSeq !== detailRequestSeq || selectedLoopId.value !== loopId) return
    loopDetail.value = detail
  } catch (err) {
    if (requestSeq !== detailRequestSeq || selectedLoopId.value !== loopId) return
    loopDetail.value = null
    detailError.value = err instanceof Error ? err.message : String(err)
  } finally {
    if (requestSeq !== detailRequestSeq) return
    detailLoading.value = false
  }
}

function selectLoop(loopId: string) {
  selectedLoopId.value = loopId
  loadDetail(loopId)
}

// --- Helpers ---

function statusLabel(status: string): string {
  switch (status) {
    case 'running': return '실행 중'
    case 'completed': return '완료'
    case 'stopped': return '중단'
    case 'error': return '오류'
    default: return status
  }
}

function statusColor(status: string): string {
  switch (status) {
    case 'running': return 'text-green-400'
    case 'completed': return 'text-blue-400'
    case 'stopped': return 'text-yellow-400'
    case 'error': return 'text-red-400'
    default: return 'text-[var(--text-muted)]'
  }
}

function decisionLabel(decision: string): string {
  return decision === 'keep' ? '유지' : '삭제'
}

function formatDelta(delta: number): string {
  const sign = delta >= 0 ? '+' : ''
  return `${sign}${delta.toFixed(4)}`
}

function formatTimestamp(ts: number): string {
  return new Date(ts * 1000).toLocaleString('ko-KR', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function liveLabel(loop: Pick<AutoresearchLoopSummary, 'live'>): string {
  return loop.live ? '실시간' : '저장됨'
}

function formatUpdatedAt(ts: number | null): string {
  if (ts == null) return '알 수 없음'
  return formatTimestamp(ts)
}

// --- Sub-components ---

function LoopSelector() {
  const loops = loopsData.value?.loops ?? []
  if (loops.length === 0) return null

  return html`
    <div class="flex flex-wrap gap-2">
      ${loops.map(loop => {
        const isSelected = loop.loop_id === selectedLoopId.value
        const cls = isSelected
          ? 'px-3 py-1.5 rounded-lg text-xs font-medium border border-accent/60 bg-accent/10 text-[var(--text-strong)] cursor-pointer'
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
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">모델</div>
            <div class="text-[var(--text-body)] text-sm font-mono">${loop.model_model}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">소스</div>
            <div class="text-[var(--text-body)] text-sm">${liveLabel(loop)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-0.5">최근 갱신</div>
            <div class="text-[var(--text-body)] text-sm font-mono">${formatUpdatedAt(loop.updated_at)}</div>
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
            <div class="text-green-400 text-sm font-mono font-semibold">${loop.best_score.toFixed(4)}</div>
          </div>
        </div>
        <div>
          <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] mb-1">유지 / 삭제</div>
          <div class="flex items-center gap-2">
            <span class="text-green-400 text-sm font-mono font-semibold">${loop.total_keeps}</span>
            <span class="text-[var(--text-muted)] text-xs">/</span>
            <span class="text-red-400 text-sm font-mono font-semibold">${loop.total_discards}</span>
            <span class="text-[var(--text-muted)] text-xs ml-1">(${keepPct}% keep)</span>
          </div>
          ${totalCycles > 0 ? html`
            <div class="mt-1.5 h-2 rounded-full bg-[var(--white-6)] overflow-hidden flex">
              <div
                class="h-full bg-green-500/70 transition-[width] duration-300"
                style=${{ width: `${(loop.total_keeps / totalCycles) * 100}%` }}
              />
              <div
                class="h-full bg-red-500/40 transition-[width] duration-300"
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
      <div class="mt-3 px-3 py-2 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-xs">
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
    <div class="overflow-x-auto">
      <table class="w-full text-xs">
        <thead>
          <tr class="text-[var(--text-muted)] text-[10px] uppercase tracking-wider border-b border-card-border">
            <th class="text-left py-2 px-2 font-medium">#</th>
            <th class="text-left py-2 px-2 font-medium">가설</th>
            <th class="text-right py-2 px-2 font-medium">이전</th>
            <th class="text-right py-2 px-2 font-medium">이후</th>
            <th class="text-right py-2 px-2 font-medium">변화</th>
            <th class="text-center py-2 px-2 font-medium">판정</th>
            <th class="text-right py-2 px-2 font-medium">시간</th>
          </tr>
        </thead>
        <tbody>
          ${cycles.map(c => html`
            <tr key=${c.cycle} class="border-b border-card-border/50 hover:bg-white/[0.02]">
              <td class="py-1.5 px-2 font-mono text-[var(--text-muted)]">${c.cycle}</td>
              <td class="py-1.5 px-2 text-[var(--text-body)] max-w-[200px] truncate" title=${c.hypothesis}>${c.hypothesis}</td>
              <td class="py-1.5 px-2 text-right font-mono text-[var(--text-body)]">${c.score_before.toFixed(4)}</td>
              <td class="py-1.5 px-2 text-right font-mono text-[var(--text-body)]">${c.score_after.toFixed(4)}</td>
              <td class="py-1.5 px-2 text-right font-mono ${c.delta >= 0 ? 'text-green-400' : 'text-red-400'}">${formatDelta(c.delta)}</td>
              <td class="py-1.5 px-2 text-center">
                <span class="px-1.5 py-0.5 rounded text-[10px] font-semibold ${
                  c.decision === 'keep'
                    ? 'bg-green-500/15 text-green-400'
                    : 'bg-red-500/15 text-red-400'
                }">${decisionLabel(c.decision)}</span>
              </td>
              <td class="py-1.5 px-2 text-right text-[var(--text-muted)] font-mono">${formatTimestamp(c.timestamp)}</td>
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
        <div key=${i} class="px-3 py-1.5 rounded-lg bg-yellow-500/10 border border-yellow-500/20 text-yellow-400 text-xs">
          ${w}
        </div>
      `)}
    </div>
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
      <div class="px-3 py-2 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-xs">
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
                class="px-2.5 py-1 rounded text-[11px] text-red-400 border border-red-500/30 hover:border-red-400/50 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
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
          <div class="mt-3 px-3 py-2 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-xs">
            ${loopActionError.value}
          </div>
        ` : null}
      <//>

      ${warnings.length > 0 ? html`
        <${SurfaceCard} variant="compact">
          <div class="text-[10px] uppercase tracking-wider text-yellow-400/80 mb-3 font-medium">경고</div>
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

  if (loopsLoading.value && !loopsData.value) {
    return html`<${EmptyState} message="오토리서치 루프 데이터를 불러오는 중..." />`
  }

  if (loopsError.value) {
    return html`
      <div class="flex flex-col gap-4">
        <div class="px-4 py-3 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-sm">
          ${loopsError.value}
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

  const loops = loopsData.value?.loops ?? []

  if (loops.length === 0) {
    return html`<${EmptyState} message="실행된 오토리서치 루프가 없습니다." icon="🔬" />`
  }

  return html`
    <div class="flex flex-col gap-5">
      <div class="flex items-center justify-between">
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">
          전체 ${loops.length}개 루프
        </div>
        <button type="button"
          class="px-2.5 py-1 rounded text-[11px] text-[var(--text-muted)] border border-card-border hover:text-[var(--text-body)] hover:border-accent/40 transition-colors"
          onClick=${() => { void refreshAutoresearchSurface() }}
        >
          새로고침
        </button>
      </div>

      <${LoopSelector} />
      <${LoopDetailView} />
    </div>
  `
}

async function runLoopAction(action: () => Promise<unknown>) {
  loopActionBusy.value = true
  loopActionError.value = null
  try {
    await action()
    await refreshAutoresearchSurface()
  } catch (err) {
    loopActionError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loopActionBusy.value = false
  }
}

async function retrySelectedLoop() {
  const loop = selectedLoop.value
  if (!loop?.loop_id) return
  await runLoopAction(() => retryAutoresearchLoop(loop.loop_id))
}

async function deleteSelectedLoop() {
  const loop = selectedLoop.value
  if (!loop?.loop_id) return
  await runLoopAction(() => deleteAutoresearchLoop(loop.loop_id))
}
