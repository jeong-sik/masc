import { html } from 'htm/preact'
import { TimeAgo } from './common/time-ago'
import { formatDuration } from '../lib/format-time'
import { keeperActivityDisplay, keeperWorkPreview } from '../lib/keeper-runtime-display'
import type { Keeper } from '../types'

// SSOT: 활동 시간 표시는 raw `keeper.last_heartbeat`를 직접 읽지 않고
// `keeperActivityDisplay()`로 통일한다. 헤드라인/사이드바/헤더가
// 같은 helper를 소비해 다른 timestamp field가 동시에 렌더링되는
// "26초 전 / 18시간 전 / 27일 전" 3중 표시 모순을 봉인한다.
export function KeeperActivitySummary({ keeper }: { keeper: Keeper }) {
  const activity = keeperActivityDisplay(keeper, keeper.agent?.last_seen)
  const workPreview = keeperWorkPreview(keeper)
  const hasActivitySignal = activity.source !== 'none' && activity.source !== 'created'
  const hasActivity =
    hasActivitySignal ||
    workPreview ||
    keeper.memory_recent_note ||
    (keeper.k2k_count ?? 0) > 0

  if (!hasActivity) return null

  return html`
    <div class="flex flex-wrap items-start gap-3 px-1 v2-monitoring-row">
      ${hasActivitySignal
        ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
            ${activity.label}
            ${activity.timestamp
              ? html`<${TimeAgo} timestamp=${activity.timestamp} />`
              : activity.ageSeconds != null
                ? html`${formatDuration(activity.ageSeconds)} 전`
                : null}
          </span>`
        : null}
      ${(keeper.k2k_count ?? 0) > 0
        ? html`<span class="inline-flex items-center gap-1 text-2xs px-2.5 py-1 rounded-[var(--r-1)] bg-[var(--info-soft)] border border-[var(--info-border)] text-[var(--color-fg-muted)]">
            K2K <span class="font-mono font-medium text-[var(--info-fg)]">${keeper.k2k_count}</span>
          </span>`
        : null}
      ${keeper.memory_recent_note
        ? html`<span class="text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] truncate max-w-90" title=${keeper.memory_recent_note}>${keeper.memory_recent_note}</span>`
        : null}
    </div>
    ${workPreview
      ? html`<div class="py-2 px-3 rounded-[var(--r-1)] bg-[var(--accent-6)] border border-[var(--accent-12)] text-xs text-[var(--color-fg-primary)] leading-relaxed v2-monitoring-panel">
          <div class="line-clamp-2">${workPreview}</div>
        </div>`
      : null}
  `
}
