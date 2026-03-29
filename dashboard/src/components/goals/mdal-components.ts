// MDAL loop display component

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { StatusBadge } from '../common/status-badge'
import { showToast } from '../common/toast'
import { formatElapsedCompact } from '../../lib/format-time'
import { stopMdalLoop } from '../../api/mdal'
import { refreshMdal } from '../../store'
import type { MdalLoop } from '../../types'
import { formatMetric, formatMetricDelta } from './goal-helpers'

const stoppingLoops = signal<Record<string, boolean>>({})

export function LoopRow({ loop }: { loop: MdalLoop }) {
  const latest = loop.history[0]
  const latestToolSummary =
    loop.latest_tool_names && loop.latest_tool_names.length > 0
      ? `${loop.latest_tool_call_count ?? loop.latest_tool_names.length}개 도구: ${loop.latest_tool_names.join(', ')}`
      : '아직 근거 없음'

  return html`
    <div class="planning-loop-row rounded-xl">
      <div class="grid gap-3">
        <div class="flex justify-between gap-3 items-start flex-wrap">
          <div>
            <div class="text-[var(--text-strong)] text-lg font-semibold capitalize">${loop.profile}</div>
            <div class="text-[var(--text-muted)] text-[11px] mt-0.5 font-mono">${loop.loop_id}</div>
          </div>
          <div class="flex gap-1.5 flex-wrap items-center">
            <${StatusBadge} status=${loop.status} />
            <span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${loop.current_iteration}${loop.max_iterations > 0 ? `/${loop.max_iterations}` : ''}</span>
            ${loop.status === 'running' || loop.status === 'active' ? html`
              <button type="button"
                class="text-[10px] py-0.5 px-2 rounded-full border border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)] text-[#fb7185] hover:bg-[rgba(239,68,68,0.15)] transition-colors cursor-pointer disabled:opacity-50"
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

        <div class="flex gap-3 flex-wrap text-[#b9c9ea] text-[13px]">
          <span>기준값 ${formatMetric(loop.baseline_metric)}</span>
          <span>현재 ${formatMetric(loop.current_metric)}</span>
          <span class=${formatMetricDelta(loop).startsWith('+') ? 'text-[#9af3ba]' : 'text-[#fda4af]'}>
            Delta ${formatMetricDelta(loop)}
          </span>
          <span>경과 ${formatElapsedCompact(loop.elapsed_seconds)}</span>
        </div>

        <div class="text-[var(--text-body)] text-base leading-[1.5]">${loop.target || '명시된 목표가 없습니다'}</div>
        ${(loop.stop_reason || loop.error_message)
          ? html`
              <div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">
                ${loop.error_message ?? loop.stop_reason}
              </div>
            `
          : null}
        <div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">
          ${loop.strict_mode ? '엄격 근거 모드' : '레거시'} · ${loop.worker_engine ?? '엔진 정보 없음'} · ${latestToolSummary}
        </div>
        ${latest
          ? html`
              <div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">
                최근 반복 #${latest.iteration}: ${latest.changes || latest.next_suggestion || '서술 정보 없음'}
              </div>
            `
          : html`<div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `
}
