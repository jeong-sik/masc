import { html } from 'htm/preact'

import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_FLEET_WARN } from '../config/constants'
import { summarizeKeeperMonitoring } from '../lib/monitoring-runtime'
import type { Keeper } from '../types/core'

type ToneKey = 'ok' | 'warn' | 'paused' | 'muted'

function MetricPill({
  label,
  value,
  tone = 'muted',
}: {
  label: string
  value: string | number
  tone?: ToneKey
}) {
  const style =
    tone === 'ok'
      ? 'text-[var(--ok)] bg-[rgba(52,211,153,0.12)] border-[rgba(52,211,153,0.2)]'
      : tone === 'warn'
        ? 'text-[var(--warn)] bg-[rgba(251,191,36,0.12)] border-[rgba(251,191,36,0.2)]'
        : tone === 'paused'
          ? 'text-[#a78bfa] bg-[rgba(167,139,250,0.12)] border-[rgba(167,139,250,0.2)]'
          : 'text-[var(--text-muted)] bg-[var(--white-4)] border-[var(--white-8)]'

  return html`
    <span class="inline-flex items-center gap-1 rounded-full border px-2 py-1 text-[10px] font-medium ${style}">
      <span>${label}</span>
      <span class="font-mono text-[var(--text-strong)]">${value}</span>
    </span>
  `
}

function FleetSummary({ keepers }: { keepers: Keeper[] }) {
  const counts = keepers.reduce(
    (acc, keeper) => {
      acc[summarizeKeeperMonitoring(keeper).band.key] += 1
      return acc
    },
    { active: 0, attention: 0, paused: 0, offline: 0 },
  )
  const avgCtx = keepers.reduce((sum, keeper) => sum + (keeper.context_ratio ?? 0), 0) / (keepers.length || 1)
  const totalTools = keepers.reduce((sum, keeper) => sum + (keeper.latest_tool_call_count ?? keeper.metrics_window?.tool_call_count ?? 0), 0)
  const totalCompactions = keepers.reduce((sum, keeper) => sum + (keeper.compaction_count ?? 0), 0)
  const compactKeepers = keepers.filter(keeper => keeper.metrics_window?.compaction_saved_ratio != null)
  const avgSavedRatio = compactKeepers.length > 0
    ? compactKeepers.reduce((sum, keeper) => sum + (keeper.metrics_window?.compaction_saved_ratio ?? 0), 0) / compactKeepers.length
    : null

  return html`
    <div class="grid gap-3 md:grid-cols-[1.5fr_1fr]">
      <div class="grid gap-2 sm:grid-cols-4">
        <${MetricPill} label="가동중" value=${counts.active} tone="ok" />
        <${MetricPill} label="주의 필요" value=${counts.attention} tone="warn" />
        <${MetricPill} label="일시정지" value=${counts.paused} tone="paused" />
        <${MetricPill} label="오프라인" value=${counts.offline} />
      </div>
      <div class="flex flex-wrap justify-start gap-2 md:justify-end">
        <${MetricPill}
          label="평균 CTX"
          value=${`${(avgCtx * 100).toFixed(0)}%`}
          tone=${avgCtx > CONTEXT_RATIO_CRITICAL ? 'warn' : avgCtx > CONTEXT_RATIO_FLEET_WARN ? 'paused' : 'ok'}
        />
        <${MetricPill} label="최근 도구" value=${totalTools} />
        ${totalCompactions > 0 ? html`
          <${MetricPill}
            label="압축"
            value=${avgSavedRatio == null ? totalCompactions : `${totalCompactions} / ${(avgSavedRatio * 100).toFixed(0)}%`}
            tone=${avgSavedRatio != null && avgSavedRatio >= 0.4 ? 'ok' : avgSavedRatio != null ? 'warn' : 'muted'}
          />
        ` : null}
      </div>
    </div>
  `
}

export function KeeperFleetOverview({ keepers: allKeepers }: { keepers: Keeper[] }) {
  if (allKeepers.length === 0) return null

  return html`
    <section class="monitor-surface-card monitor-surface-card-medium mb-6 p-4 md:p-5">
      <div class="flex flex-col gap-4">
        <div class="flex flex-col gap-1.5">
          <div class="text-[11px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">키퍼 운영 요약</div>
          <h3 class="m-0 text-[18px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">키퍼 fleet 상태만 먼저 요약합니다</h3>
          <p class="m-0 max-w-[720px] text-[12px] leading-[1.6] text-[var(--text-body)]">
            여기서는 fleet 상태만 요약하고, 상세 확인은 아래 통합 목록에서 같은 기준으로 이어서 봅니다.
          </p>
        </div>

        <${FleetSummary} keepers=${allKeepers} />
      </div>
    </section>
  `
}
