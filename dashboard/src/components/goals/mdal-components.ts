// MDAL loop display + start form component

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { StatusBadge } from '../common/status-badge'
import { DialogOverlay } from '../common/dialog'
import { TextInput } from '../common/input'
import { RouteLink } from '../common/route-link'
import { showToast } from '../common/toast'
import { formatElapsedCompact } from '../../lib/format-time'
import { startMdalLoop, stopMdalLoop, type StartMdalLoopParams } from '../../api/mdal'
import { refreshMdal } from '../../store'
import type { MdalLoop } from '../../types'
import { formatMetric, formatMetricDelta } from './goal-helpers'

const stoppingLoops = signal<Record<string, boolean>>({})

// --- MDAL Start Form state ---
const MDAL_PROFILES = ['custom', 'ssim', 'coverage', 'lint', 'review', 'docs'] as const

export const showMdalStartForm = signal(false)
const mdalStartBusy = signal(false)
const mdalStartError = signal<string | null>(null)
const mdalProfile = signal('custom')
const mdalMetricFn = signal('')
const mdalGoal = signal('')
const mdalTarget = signal('')
const mdalMaxIterations = signal('20')

function resetMdalStartForm() {
  mdalProfile.value = 'custom'
  mdalMetricFn.value = ''
  mdalGoal.value = ''
  mdalTarget.value = ''
  mdalMaxIterations.value = '20'
  mdalStartError.value = null
}

const mdalCanSubmit = computed(() =>
  mdalProfile.value.trim() !== '' && mdalMetricFn.value.trim() !== '' && !mdalStartBusy.value
)

async function handleMdalStartSubmit() {
  mdalStartBusy.value = true
  mdalStartError.value = null
  try {
    const params: StartMdalLoopParams = {
      profile: mdalProfile.value,
      metric_fn: mdalMetricFn.value.trim(),
    }
    const goal = mdalGoal.value.trim()
    if (goal) params.goal = goal
    const target = mdalTarget.value.trim()
    if (target) params.target = target
    const maxIter = parseInt(mdalMaxIterations.value, 10)
    if (Number.isFinite(maxIter) && maxIter > 0) params.max_iterations = maxIter

    const result = await startMdalLoop(params)
    if (!result.ok) {
      mdalStartError.value = result.error ?? '알 수 없는 오류'
      return
    }
    showMdalStartForm.value = false
    resetMdalStartForm()
    showToast('MDAL 루프가 시작되었습니다', 'success')
    refreshMdal()
  } catch (err) {
    mdalStartError.value = err instanceof Error ? err.message : String(err)
  } finally {
    mdalStartBusy.value = false
  }
}

export function MdalStartFormButton() {
  return html`
    <button type="button"
      class="rounded-lg border border-accent/35 bg-accent/10 px-3 py-1.5 text-[12px] font-medium text-accent transition-colors hover:bg-accent/16"
      onClick=${() => { showMdalStartForm.value = true }}
    >
      새 루프 시작
    </button>
  `
}

export function MdalStartFormDialog() {
  if (!showMdalStartForm.value) return null

  return html`
    <${DialogOverlay}
      labelledBy="start-mdal-title"
      onClose=${() => { showMdalStartForm.value = false; mdalStartError.value = null }}
      overlayClass="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      panelClass="w-full max-w-lg mx-4 rounded-xl border border-card-border bg-[var(--card-bg)] shadow-2xl p-6"
    >
      <h2 id="start-mdal-title" class="text-sm font-semibold text-[var(--text-strong)] mb-4">
        새 MDAL 루프
      </h2>

      <div class="flex flex-col gap-3">
        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">프로필 *</span>
          <select
            class="w-full px-3 py-2 rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] focus-visible:outline-none focus-visible:border-[rgba(71,184,255,0.5)]"
            value=${mdalProfile.value}
            onChange=${(e: Event) => { mdalProfile.value = (e.target as HTMLSelectElement).value }}
          >
            ${MDAL_PROFILES.map(p => html`<option value=${p}>${p}</option>`)}
          </select>
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">메트릭 명령어 *</span>
          <${TextInput}
            value=${mdalMetricFn.value}
            placeholder="float를 출력하는 shell 명령 (예: python measure.py)"
            onInput=${(e: Event) => { mdalMetricFn.value = (e.target as HTMLInputElement).value }}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)] font-medium">목표 조건 ${mdalProfile.value === 'custom' ? '*' : ''}</span>
          <${TextInput}
            value=${mdalGoal.value}
            placeholder="예: metric >= 0.95 또는 errors <= 0"
            onInput=${(e: Event) => { mdalGoal.value = (e.target as HTMLInputElement).value }}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">대상 설명</span>
          <${TextInput}
            value=${mdalTarget.value}
            placeholder="사람이 읽을 수 있는 대상 설명"
            onInput=${(e: Event) => { mdalTarget.value = (e.target as HTMLInputElement).value }}
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">최대 반복</span>
          <${TextInput}
            type="number"
            value=${mdalMaxIterations.value}
            placeholder="20"
            onInput=${(e: Event) => { mdalMaxIterations.value = (e.target as HTMLInputElement).value }}
          />
        </label>

        ${mdalStartError.value ? html`
          <div class="px-3 py-2 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-xs">
            ${mdalStartError.value}
          </div>
        ` : null}

        <div class="flex items-center justify-end gap-2 mt-2">
          <button type="button"
            class="px-3 py-1.5 rounded-lg text-xs font-medium border border-card-border text-[var(--text-muted)] hover:text-[var(--text-body)] transition-colors"
            onClick=${() => { showMdalStartForm.value = false; mdalStartError.value = null }}
            disabled=${mdalStartBusy.value}
          >
            취소
          </button>
          <button type="button"
            class="px-4 py-1.5 rounded-lg text-xs font-semibold border transition-colors ${
              mdalCanSubmit.value
                ? 'border-accent/60 bg-accent/15 text-accent hover:bg-accent/25'
                : 'border-card-border bg-card/60 text-[var(--text-muted)] cursor-not-allowed opacity-50'
            }"
            disabled=${!mdalCanSubmit.value}
            onClick=${() => { void handleMdalStartSubmit() }}
          >
            ${mdalStartBusy.value ? '시작 중...' : '시작'}
          </button>
        </div>
      </div>
    <//>
  `
}

export function LoopRow({ loop }: { loop: MdalLoop }) {
  const latest = loop.history[0]
  const latestToolSummary =
    loop.latest_tool_names && loop.latest_tool_names.length > 0
      ? `${loop.latest_tool_call_count ?? loop.latest_tool_names.length}개 도구: ${loop.latest_tool_names.join(', ')}`
      : '아직 근거 없음'

  return html`
    <div class="rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] p-4">
      <div class="grid gap-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="rounded-md border border-card-border/70 bg-white/5 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.16em] text-text-muted">
                ${loop.profile}
              </span>
              <${StatusBadge} status=${loop.status} />
              <span class="rounded-md border border-card-border/70 bg-white/5 px-2 py-0.5 text-[10px] font-semibold text-text-body">
                ${loop.current_iteration}${loop.max_iterations > 0 ? `/${loop.max_iterations}` : ''}
              </span>
            </div>
            <div class="mt-2 text-[16px] font-semibold leading-snug text-text-strong">
              ${loop.target || '명시된 목표가 없습니다'}
            </div>
            <div class="mt-1 text-[11px] font-mono text-text-dim">${loop.loop_id}</div>
          </div>
          <div class="flex flex-wrap items-center gap-1.5">
            ${loop.session_id ? html`
              <${RouteLink}
                tab="monitoring"
                params=${{ section: 'sessions', session_id: loop.session_id }}
                class="rounded-lg border border-card-border/70 bg-white/4 px-2.5 py-1 text-[11px] font-medium text-text-body transition-colors hover:border-accent/35 hover:text-text-strong"
              >
                세션 ${loop.session_id}
              <//>
            ` : null}
            ${loop.status === 'running' ? html`
              <button type="button"
                class="rounded-lg border border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)] px-2.5 py-1 text-[11px] font-medium text-[#fb7185] transition-colors hover:bg-[rgba(239,68,68,0.15)] cursor-pointer disabled:opacity-50"
                disabled=${stoppingLoops.value[loop.loop_id] ?? false}
                onClick=${() => {
                  stoppingLoops.value = { ...stoppingLoops.value, [loop.loop_id]: true }
                  void stopMdalLoop(loop.loop_id).then(res => {
                    if (res.ok) { showToast(`${loop.profile} 루프 중지됨`, 'success'); refreshMdal() }
                    else showToast(res.error ?? '중지 실패', 'error')
                  }).catch(err => {
                    showToast(err instanceof Error ? err.message : '중지 실패', 'error')
                  }).finally(() => {
                    stoppingLoops.value = { ...stoppingLoops.value, [loop.loop_id]: false }
                  })
                }}
              >
                ${(stoppingLoops.value[loop.loop_id] ?? false) ? '중지 중...' : '중지'}
              </button>
            ` : null}
          </div>
        </div>

        <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-lg border border-card-border/60 bg-white/4 px-3 py-2">
            <div class="text-[10px] uppercase tracking-[0.16em] text-text-muted">기준값</div>
            <div class="mt-1 text-[15px] font-semibold text-text-strong">${formatMetric(loop.baseline_metric)}</div>
          </div>
          <div class="rounded-lg border border-card-border/60 bg-white/4 px-3 py-2">
            <div class="text-[10px] uppercase tracking-[0.16em] text-text-muted">현재값</div>
            <div class="mt-1 text-[15px] font-semibold text-text-strong">${formatMetric(loop.current_metric)}</div>
          </div>
          <div class="rounded-lg border border-card-border/60 bg-white/4 px-3 py-2">
            <div class="text-[10px] uppercase tracking-[0.16em] text-text-muted">Delta</div>
            <div class="mt-1 text-[15px] font-semibold ${formatMetricDelta(loop).startsWith('+') ? 'text-ok' : 'text-bad'}">
              ${formatMetricDelta(loop)}
            </div>
          </div>
          <div class="rounded-lg border border-card-border/60 bg-white/4 px-3 py-2">
            <div class="text-[10px] uppercase tracking-[0.16em] text-text-muted">경과</div>
            <div class="mt-1 text-[15px] font-semibold text-text-strong">${formatElapsedCompact(loop.elapsed_seconds)}</div>
          </div>
        </div>

        ${(loop.stop_reason || loop.error_message)
          ? html`
              <div class="rounded-lg border border-bad/20 bg-bad/10 px-3 py-2 text-[13px] leading-[1.5] text-bad">
                ${loop.error_message ?? loop.stop_reason}
              </div>
            `
          : null}

        <div class="flex flex-wrap gap-2 text-[11px] text-text-muted">
          <span class="rounded-md border border-card-border/60 bg-white/4 px-2 py-1">${loop.strict_mode ? '엄격 근거 모드' : '레거시 모드'}</span>
          <span class="rounded-md border border-card-border/60 bg-white/4 px-2 py-1">${loop.worker_engine ?? '엔진 정보 없음'}</span>
          ${loop.worker_model ? html`<span class="rounded-md border border-card-border/60 bg-white/4 px-2 py-1">${loop.worker_model}</span>` : null}
          <span class="rounded-md border border-card-border/60 bg-white/4 px-2 py-1">${latestToolSummary}</span>
        </div>

        ${latest
          ? html`
              <div class="rounded-lg border border-card-border/60 bg-white/4 px-3 py-2 text-[13px] leading-[1.6] text-text-body">
                최근 반복 #${latest.iteration}: ${latest.changes || latest.next_suggestion || '서술 정보 없음'}
              </div>
            `
          : html`<div class="text-[13px] leading-[1.5] text-text-muted">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `
}
