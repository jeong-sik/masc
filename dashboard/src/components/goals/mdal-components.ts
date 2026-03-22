// MDAL loop display component

import { html } from 'htm/preact'
import { StatusBadge } from '../common/status-badge'
import { formatElapsedCompact } from '../../lib/format-time'
import type { MdalLoop } from '../../types'
import { formatMetric, formatMetricDelta } from './goal-helpers'

export function LoopRow({ loop }: { loop: MdalLoop }) {
  const latest = loop.history[0]
  const latestToolSummary =
    loop.latest_tool_names && loop.latest_tool_names.length > 0
      ? `${loop.latest_tool_call_count ?? loop.latest_tool_names.length}개 도구: ${loop.latest_tool_names.join(', ')}`
      : '아직 근거 없음'

  return html`
    <div class="planning-loop-row rounded-xl">
      <div class="grid gap-2.5">
        <div class="flex justify-between gap-3 items-start flex-wrap">
          <div>
            <div class="text-[color:var(--text-strong)] text-[length:var(--fs-lg)] font-semibold capitalize">${loop.profile}</div>
            <div class="text-[color:var(--text-muted)] text-[length:var(--fs-xs)] mt-0.5 font-mono">${loop.loop_id}</div>
          </div>
          <div class="flex gap-1.5 flex-wrap">
            <${StatusBadge} status=${loop.status} />
            <span class="text-[length:var(--fs-2xs)] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${loop.current_iteration}${loop.max_iterations > 0 ? `/${loop.max_iterations}` : ''}</span>
          </div>
        </div>

        <div class="flex gap-2.5 flex-wrap text-[#b9c9ea] text-[length:var(--fs-sm)]">
          <span>Baseline ${formatMetric(loop.baseline_metric)}</span>
          <span>현재 ${formatMetric(loop.current_metric)}</span>
          <span class=${formatMetricDelta(loop).startsWith('+') ? 'text-[#9af3ba]' : 'text-[#fda4af]'}>
            Delta ${formatMetricDelta(loop)}
          </span>
          <span>Elapsed ${formatElapsedCompact(loop.elapsed_seconds)}</span>
        </div>

        <div class="text-[color:var(--text-body)] text-[length:var(--fs-base)] leading-[1.5]">${loop.target || '명시된 목표가 없습니다'}</div>
        ${(loop.stop_reason || loop.error_message)
          ? html`
              <div class="text-[color:var(--text-muted)] text-[length:var(--fs-sm)] leading-[1.5]">
                ${loop.error_message ?? loop.stop_reason}
              </div>
            `
          : null}
        <div class="text-[color:var(--text-muted)] text-[length:var(--fs-sm)] leading-[1.5]">
          ${loop.strict_mode ? '엄격 근거 모드' : '레거시'} · ${loop.worker_engine ?? '엔진 정보 없음'} · ${latestToolSummary}
        </div>
        ${latest
          ? html`
              <div class="text-[color:var(--text-muted)] text-[length:var(--fs-sm)] leading-[1.5]">
                최근 반복 #${latest.iteration}: ${latest.changes || latest.next_suggestion || '서술 정보 없음'}
              </div>
            `
          : html`<div class="text-[color:var(--text-muted)] text-[length:var(--fs-sm)] leading-[1.5]">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `
}
