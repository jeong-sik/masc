// Autoresearch "Start New Loop" form.
// Extracted from autoresearch.ts to separate form logic from main UI.

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { DialogOverlay } from './common/dialog'
import { TextInput, TextArea } from './common/input'
import {
  AUTORESEARCH_DEFAULT_MAX_CYCLES,
  AUTORESEARCH_DEFAULT_CYCLE_TIMEOUT_S,
  AUTORESEARCH_DEFAULT_MODEL,
} from '../config/constants'
import {
  startAutoresearchLoop,
  type StartAutoresearchLoopParams,
} from '../api'
import { refreshAutoresearchSurface } from './autoresearch-state'

// --- Form signals ---

export const showStartForm = signal(false)
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

// --- Form helpers ---

export function resetStartFormFields() {
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

// --- Components ---

export function StartFormButton({ class: cx }: { class?: string }) {
  return html`
    <button type="button"
      class=${cx ?? 'px-3 py-1.5 rounded text-xs font-medium border border-accent/50 text-accent hover:bg-[var(--accent-10)] transition-colors'}
      onClick=${() => { showStartForm.value = true }}
    >
      새 루프 시작
    </button>
  `
}

const canSubmit = computed(() =>
  formGoal.value.trim() !== '' && formMetricFn.value.trim() !== '' && formTargetFile.value.trim() !== '' && !startFormBusy.value
)

export function StartAutoresearchForm() {

  return html`
    <${DialogOverlay}
      labelledBy="start-autoresearch-title"
      onClose=${closeStartForm}
      overlayClass="fixed inset-0 z-50 flex items-center justify-center bg-[var(--white-5)]/60 backdrop-blur-sm"
      panelClass="w-full max-w-lg mx-4 rounded border border-card-border bg-[var(--card-bg)] shadow-sm p-6"
    >
      <h2 id="start-autoresearch-title" class="text-sm font-semibold text-[var(--text-strong)] mb-4">
        새 오토리서치 루프
      </h2>

      <div class="flex flex-col gap-3">
        <label class="flex flex-col gap-1">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)] font-medium">목표 *</span>
          <${TextArea}
            value=${formGoal.value}
            placeholder="최적화 목표 (예: Reduce inference latency by optimizing hot path)"
            rows=${2}
            onInput=${inputHandler(formGoal)}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)] font-medium">메트릭 명령어 *</span>
          <${TextInput}
            value=${formMetricFn.value}
            placeholder="마지막 줄에 float를 출력하는 명령어 (예: python eval.py --metric accuracy)"
            onInput=${inputHandler(formMetricFn)}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)] font-medium">대상 파일 *</span>
          <${TextInput}
            value=${formTargetFile.value}
            placeholder="수정할 파일 경로 (예: lib/optimizer.ml)"
            onInput=${inputHandler(formTargetFile)}
          />
        </label>

        <button type="button"
          class="self-start text-2xs text-[var(--text-muted)] hover:text-[var(--text-body)] transition-colors"
          onClick=${() => { formShowAdvanced.value = !formShowAdvanced.value }}
        >
          ${formShowAdvanced.value ? '고급 설정 접기 \u25B2' : '고급 설정 \u25BC'}
        </button>

        ${formShowAdvanced.value ? html`
          <div class="grid grid-cols-2 gap-3 border-t border-card-border pt-3">
            <label class="flex flex-col gap-1">
              <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">작업 디렉토리</span>
              <${TextInput}
                value=${formWorkdir.value}
                placeholder="기본: 프로젝트 루트"
                onInput=${inputHandler(formWorkdir)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">모델</span>
              <${TextInput}
                value=${formModelModel.value}
                placeholder="glm"
                onInput=${inputHandler(formModelModel)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">최대 사이클</span>
              <${TextInput}
                type="number"
                value=${formMaxCycles.value}
                placeholder="100"
                onInput=${inputHandler(formMaxCycles)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">사이클 타임아웃 (초)</span>
              <${TextInput}
                type="number"
                value=${formCycleTimeoutS.value}
                placeholder="300"
                onInput=${inputHandler(formCycleTimeoutS)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">기준선 (baseline)</span>
              <${TextInput}
                type="number"
                value=${formBaseline.value}
                placeholder="자동 측정 (빈칸)"
                onInput=${inputHandler(formBaseline)}
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">인내 (patience)</span>
              <${TextInput}
                type="number"
                value=${formPatience.value}
                placeholder="기본값 사용"
                onInput=${inputHandler(formPatience)}
              />
            </label>
            <label class="col-span-2 flex flex-col gap-1">
              <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">빌드 검증 명령어</span>
              <${TextInput}
                value=${formBuildVerifyFn.value}
                placeholder="선택 (예: dune build)"
                onInput=${inputHandler(formBuildVerifyFn)}
              />
            </label>
          </div>
        ` : null}

        ${startFormError.value ? html`
          <div class="px-3 py-2 rounded bg-[var(--bad-10)] border border-[var(--bad-20)] text-[var(--bad)] text-xs">
            ${startFormError.value}
          </div>
        ` : null}

        <div class="flex items-center justify-end gap-2 mt-2">
          <button type="button"
            class="px-3 py-1.5 rounded text-xs font-medium border border-card-border text-[var(--text-muted)] hover:text-[var(--text-body)] transition-colors"
            onClick=${closeStartForm}
            disabled=${startFormBusy.value}
          >
            취소
          </button>
          <button type="button"
            class="px-4 py-1.5 rounded text-xs font-semibold border transition-colors ${
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
