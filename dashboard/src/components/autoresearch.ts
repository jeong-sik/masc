// Autoresearch Surface — Autonomous experiment loop dashboard
// Displays loop overview, keep/discard ratio, cycle history, insights, and warnings.

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { SurfaceCard } from './common/card'
import { EmptyState } from './common/empty-state'
import { DialogOverlay } from './common/dialog'
import { TextInput, TextArea } from './common/input'
import { formatElapsedCompact } from '../lib/format-time'
import { statusLabel } from '../lib/status-label'
import {
  AUTORESEARCH_DEFAULT_MAX_CYCLES,
  AUTORESEARCH_DEFAULT_CYCLE_TIMEOUT_S,
  AUTORESEARCH_DEFAULT_MODEL,
} from '../config/constants'
import { navigate } from '../router'
import {
  deleteAutoresearchLoop,
  fetchAutoresearchLoops,
  fetchAutoresearchLoopDetail,
  retryAutoresearchLoop,
  startAutoresearchLoop,
  type AutoresearchLoopsResponse,
  type AutoresearchLoopDetail,
  type AutoresearchLoopSummary,
  type AutoresearchCycleRecord,
  type StartAutoresearchLoopParams,
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

// --- Start form state ---
const showStartForm = signal(false)
const startFormBusy = signal(false)
const startFormError = signal<string | null>(null)
const formGoal = signal('')
const formMetricFn = signal('')
const formTargetFile = signal('')
const formShowAdvanced = signal(false)
const formWorkdir = signal('')
const formMaxCycles = signal(String(AUTORESEARCH_DEFAULT_MAX_CYCLES))
const formCycleTimeoutS = signal(String(AUTORESEARCH_DEFAULT_CYCLE_TIMEOUT_S))
const formModelModel = signal(AUTORESEARCH_DEFAULT_MODEL)
const formBaseline = signal('')
const formPatience = signal('')
const formBuildVerifyFn = signal('')

export function resetAutoresearchState(): void {
  loopsData.value = null
  loopsLoading.value = false
  loopsError.value = null
  selectedLoopId.value = null
  loopDetail.value = null
  detailLoading.value = false
  detailError.value = null
  loopActionBusy.value = false
  loopActionError.value = null
  loopsRequest = null
  pendingRefreshDetail = false
  detailRequestSeq = 0
  showStartForm.value = false
  startFormBusy.value = false
  startFormError.value = null
  resetStartFormFields()
}

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

function resetStartFormFields() {
  formGoal.value = ''
  formMetricFn.value = ''
  formTargetFile.value = ''
  formShowAdvanced.value = false
  formWorkdir.value = ''
  formMaxCycles.value = String(AUTORESEARCH_DEFAULT_MAX_CYCLES)
  formCycleTimeoutS.value = String(AUTORESEARCH_DEFAULT_CYCLE_TIMEOUT_S)
  formModelModel.value = AUTORESEARCH_DEFAULT_MODEL
  formBaseline.value = ''
  formPatience.value = ''
  formBuildVerifyFn.value = ''
}

function closeStartForm() {
  showStartForm.value = false
  startFormError.value = null
}

async function handleStartSubmit() {
  const goal = formGoal.value.trim()
  const metric_fn = formMetricFn.value.trim()
  const target_file = formTargetFile.value.trim()
  if (!goal || !metric_fn || !target_file) return

  startFormBusy.value = true
  startFormError.value = null
  try {
    const params: StartAutoresearchLoopParams = { goal, metric_fn, target_file }
    const workdir = formWorkdir.value.trim()
    if (workdir) params.workdir = workdir
    const maxCycles = parseInt(formMaxCycles.value, 10)
    if (Number.isFinite(maxCycles) && maxCycles > 0) params.max_cycles = maxCycles
    const cycleTimeout = parseFloat(formCycleTimeoutS.value)
    if (Number.isFinite(cycleTimeout) && cycleTimeout > 0) params.cycle_timeout_s = cycleTimeout
    const modelModel = formModelModel.value.trim()
    if (modelModel) params.model_model = modelModel
    const baseline = parseFloat(formBaseline.value)
    if (Number.isFinite(baseline)) params.baseline = baseline
    const patience = parseInt(formPatience.value, 10)
    if (Number.isFinite(patience) && patience > 0) params.patience = patience
    const buildVerifyFn = formBuildVerifyFn.value.trim()
    if (buildVerifyFn) params.build_verify_fn = buildVerifyFn

    const result = await startAutoresearchLoop(params)
    if (!result.ok) {
      startFormError.value = result.error ?? '알 수 없는 오류가 발생했습니다.'
      return
    }
    closeStartForm()
    resetStartFormFields()
    await refreshAutoresearchSurface()
  } catch (err) {
    startFormError.value = err instanceof Error ? err.message : String(err)
  } finally {
    startFormBusy.value = false
  }
}

function inputHandler(sig: { value: string }) {
  return (e: Event) => { sig.value = (e.target as HTMLInputElement).value }
}

function StartFormButton({ class: cx }: { class?: string }) {
  return html`
    <button type="button"
      class=${cx ?? 'px-3 py-1.5 rounded-lg text-xs font-medium border border-accent/50 text-accent hover:bg-accent/10 transition-colors'}
      onClick=${() => { showStartForm.value = true }}
    >
      새 루프 시작
    </button>
  `
}

const canSubmit = computed(() =>
  formGoal.value.trim() !== '' && formMetricFn.value.trim() !== '' && formTargetFile.value.trim() !== '' && !startFormBusy.value
)

function StartAutoresearchForm() {

  return html`
    <${DialogOverlay}
      labelledBy="start-autoresearch-title"
      onClose=${closeStartForm}
      overlayClass="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      panelClass="w-full max-w-lg mx-4 rounded-xl border border-card-border bg-[var(--card-bg)] shadow-2xl p-6"
    >
      <h2 id="start-autoresearch-title" class="text-sm font-semibold text-[var(--text-strong)] mb-4">
        새 오토리서치 루프
      </h2>

      <div class="flex flex-col gap-3">
        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">목표 *</span>
          <${TextArea}
            value=${formGoal.value}
            placeholder="최적화 목표 (예: Reduce inference latency by optimizing hot path)"
            rows=${2}
            onInput=${inputHandler(formGoal)}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">메트릭 명령어 *</span>
          <${TextInput}
            value=${formMetricFn.value}
            placeholder="마지막 줄에 float를 출력하는 명령어 (예: python eval.py --metric accuracy)"
            onInput=${inputHandler(formMetricFn)}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">대상 파일 *</span>
          <${TextInput}
            value=${formTargetFile.value}
            placeholder="수정할 파일 경로 (예: lib/optimizer.ml)"
            onInput=${inputHandler(formTargetFile)}
          />
        </label>

        <button type="button"
          class="self-start text-[11px] text-[var(--text-muted)] hover:text-[var(--text-body)] transition-colors"
          onClick=${() => { formShowAdvanced.value = !formShowAdvanced.value }}
        >
          ${formShowAdvanced.value ? '고급 설정 접기 \u25B2' : '고급 설정 \u25BC'}
        </button>

        ${formShowAdvanced.value ? html`
          <div class="grid grid-cols-2 gap-3 border-t border-card-border pt-3">
            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">작업 디렉토리</span>
              <${TextInput}
                value=${formWorkdir.value}
                placeholder="기본: 프로젝트 루트"
                onInput=${inputHandler(formWorkdir)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">모델</span>
              <${TextInput}
                value=${formModelModel.value}
                placeholder="glm"
                onInput=${inputHandler(formModelModel)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">최대 사이클</span>
              <${TextInput}
                type="number"
                value=${formMaxCycles.value}
                placeholder="100"
                onInput=${inputHandler(formMaxCycles)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">사이클 타임아웃 (초)</span>
              <${TextInput}
                type="number"
                value=${formCycleTimeoutS.value}
                placeholder="300"
                onInput=${inputHandler(formCycleTimeoutS)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">기준선 (baseline)</span>
              <${TextInput}
                type="number"
                value=${formBaseline.value}
                placeholder="자동 측정 (빈칸)"
                onInput=${inputHandler(formBaseline)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">인내 (patience)</span>
              <${TextInput}
                type="number"
                value=${formPatience.value}
                placeholder="기본값 사용"
                onInput=${inputHandler(formPatience)}
              />
            </label>
            <label class="col-span-2 flex flex-col gap-1">
              <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">빌드 검증 명령어</span>
              <${TextInput}
                value=${formBuildVerifyFn.value}
                placeholder="선택 (예: dune build)"
                onInput=${inputHandler(formBuildVerifyFn)}
              />
            </label>
          </div>
        ` : null}

        ${startFormError.value ? html`
          <div class="px-3 py-2 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-xs">
            ${startFormError.value}
          </div>
        ` : null}

        <div class="flex items-center justify-end gap-2 mt-2">
          <button type="button"
            class="px-3 py-1.5 rounded-lg text-xs font-medium border border-card-border text-[var(--text-muted)] hover:text-[var(--text-body)] transition-colors"
            onClick=${closeStartForm}
            disabled=${startFormBusy.value}
          >
            취소
          </button>
          <button type="button"
            class="px-4 py-1.5 rounded-lg text-xs font-semibold border transition-colors ${
              canSubmit.value
                ? 'border-accent/60 bg-accent/15 text-accent hover:bg-accent/25'
                : 'border-card-border bg-card/60 text-[var(--text-muted)] cursor-not-allowed opacity-50'
            }"
            disabled=${!canSubmit.value}
            onClick=${() => { void handleStartSubmit() }}
          >
            ${startFormBusy.value ? '시작 중...' : '시작'}
          </button>
        </div>
      </div>
    <//>
  `
}

function ResearchBrief({ loop }: { loop: AutoresearchLoopSummary }) {
  const linkedAt = loop.linked_at != null ? formatTimestamp(loop.linked_at) : '미연결'

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
            evaluator fallback, pre-compaction pressure, continuity DNA quality는 하네스에서 봅니다.
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
            class="px-2.5 py-1 rounded text-[11px] text-accent border border-accent/40 hover:bg-accent/10 transition-colors"
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
  if (typeof globalThis.confirm === 'function') {
    const confirmed = globalThis.confirm(
      `루프 ${loop.loop_id}와 연결된 worktree/branch/results를 삭제합니다. 계속할까요?`,
    )
    if (!confirmed) return
  }
  await runLoopAction(() => deleteAutoresearchLoop(loop.loop_id))
}
