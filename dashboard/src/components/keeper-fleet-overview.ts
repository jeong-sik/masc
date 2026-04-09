import { html } from 'htm/preact'

import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_FLEET_WARN } from '../config/constants'
import { keeperPhaseForDisplay, summarizeKeeperMonitoring } from '../lib/monitoring-runtime'
import type { Keeper } from '../types/core'
import { openKeeperDetail } from './keeper-detail'
import { KeeperPhaseBadge } from './keeper-phase-indicator'

type ToneKey = 'ok' | 'warn' | 'paused' | 'muted'

interface ToneStyle {
  text: string
  bg: string
  border: string
}

const BAND_STYLES: Record<string, ToneStyle> = {
  active: { text: 'var(--ok)', bg: 'rgba(52,211,153,0.12)', border: 'rgba(52,211,153,0.2)' },
  attention: { text: 'var(--warn)', bg: 'rgba(251,191,36,0.12)', border: 'rgba(251,191,36,0.2)' },
  paused: { text: '#a78bfa', bg: 'rgba(167,139,250,0.12)', border: 'rgba(167,139,250,0.22)' },
  offline: { text: 'var(--text-dim)', bg: 'var(--white-4)', border: 'var(--white-8)' },
}

const STAGE_STYLES: Record<string, ToneStyle> = {
  thinking: { text: 'var(--accent)', bg: 'rgba(71,184,255,0.12)', border: 'rgba(71,184,255,0.2)' },
  tool_use: { text: 'var(--ok)', bg: 'rgba(52,211,153,0.12)', border: 'rgba(52,211,153,0.2)' },
  compacting: { text: '#a855f7', bg: 'rgba(168,85,247,0.12)', border: 'rgba(168,85,247,0.2)' },
  handoff: { text: '#f472b6', bg: 'rgba(244,114,182,0.12)', border: 'rgba(244,114,182,0.2)' },
  scheduled_autonomous: { text: 'var(--accent)', bg: 'rgba(71,184,255,0.1)', border: 'rgba(71,184,255,0.18)' },
  failing: { text: 'var(--warn)', bg: 'rgba(251,191,36,0.12)', border: 'rgba(251,191,36,0.2)' },
  draining: { text: '#fb923c', bg: 'rgba(251,146,60,0.12)', border: 'rgba(251,146,60,0.2)' },
  paused: { text: '#a78bfa', bg: 'rgba(167,139,250,0.12)', border: 'rgba(167,139,250,0.2)' },
  restarting: { text: '#38bdf8', bg: 'rgba(56,189,248,0.12)', border: 'rgba(56,189,248,0.2)' },
  crashed: { text: 'var(--bad)', bg: 'rgba(239,68,68,0.12)', border: 'rgba(239,68,68,0.2)' },
  idle: { text: 'var(--text-dim)', bg: 'var(--white-4)', border: 'var(--white-8)' },
  offline: { text: 'var(--text-dim)', bg: 'var(--white-4)', border: 'var(--white-8)' },
}

function pillStyle(tone: ToneStyle): string {
  return `color:${tone.text};background:${tone.bg};border:1px solid ${tone.border};`
}

function ContextBar({ ratio }: { ratio: number | undefined }) {
  const pct = (ratio ?? 0) * 100
  const color = pct > 85 ? 'var(--bad)' : pct > 60 ? 'var(--warn)' : 'var(--ok)'
  return html`
    <div class="flex items-center gap-1.5">
      <div class="flex-1 h-1.5 rounded-full bg-[var(--white-6)] overflow-hidden">
        <div
          class="h-full rounded-full transition-all duration-500"
          style="width: ${pct.toFixed(0)}%; background: ${color}"
        ></div>
      </div>
      <span class="text-[10px] font-mono w-8 text-right" style="color: ${color}">
        ${pct > 0 ? `${pct.toFixed(0)}%` : '-'}
      </span>
    </div>
  `
}

function formatRecency(agoS: number | undefined): string {
  if (agoS == null) return '-'
  if (agoS < 60) return `${Math.round(agoS)}초`
  if (agoS < 3600) return `${Math.floor(agoS / 60)}분`
  if (agoS < 86400) return `${Math.floor(agoS / 3600)}시간`
  return `${Math.floor(agoS / 86400)}일`
}

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

function KeeperRow({ keeper }: { keeper: Keeper }) {
  const summary = summarizeKeeperMonitoring(keeper)
  const bandTone = BAND_STYLES[summary.band.key] ?? BAND_STYLES.offline!
  const stageTone = STAGE_STYLES[summary.stage.key] ?? STAGE_STYLES.offline!
  const toolCount = keeper.latest_tool_call_count ?? keeper.metrics_window?.tool_call_count ?? 0

  return html`
    <button
      type="button"
      class="group grid w-full gap-3 rounded-2xl border border-[var(--card-border)] bg-[linear-gradient(180deg,var(--white-2),rgba(255,255,255,0.02))] px-4 py-4 text-left transition-all duration-200 hover:-translate-y-0.5 hover:border-[var(--accent-30)] hover:bg-[linear-gradient(180deg,var(--accent-soft),rgba(255,255,255,0.04))]"
      onClick=${() => openKeeperDetail(keeper)}
      aria-label=${`${keeper.name} keeper 상세 보기`}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <span
              class="inline-flex items-center rounded-full px-2.5 py-1 text-[10px] font-semibold tracking-[0.08em] uppercase"
              style=${pillStyle(bandTone)}
              title=${summary.band.description}
            >${summary.band.label}</span>
            <${KeeperPhaseBadge} phase=${keeperPhaseForDisplay(keeper)} compact />
            <span
              class="inline-flex items-center rounded-full px-2.5 py-1 text-[10px] font-medium"
              style=${pillStyle(stageTone)}
              title=${summary.stage.description}
            >stage ${summary.stage.label}</span>
          </div>
          <div class="mt-2 flex items-center gap-2">
            <span class="truncate text-[15px] font-semibold text-[var(--text-strong)]">${keeper.name}</span>
            ${keeper.model ? html`<span class="truncate rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5 text-[10px] font-mono text-[var(--text-muted)]">${keeper.model}</span>` : null}
          </div>
          <p class="mt-2 mb-0 text-[12px] leading-[1.55] text-[var(--text-body)]">
            ${summary.hint ?? summary.phase.description}
          </p>
        </div>

        <div class="grid min-w-[208px] gap-2 text-[10px] text-[var(--text-muted)] sm:grid-cols-2">
          <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2">
            <div>컨텍스트</div>
            <div class="mt-1"><${ContextBar} ratio=${keeper.context_ratio} /></div>
          </div>
          <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2">
            <div>최근 활동</div>
            <div class="mt-1 text-[12px] font-mono text-[var(--text-strong)]">${formatRecency(keeper.last_activity_ago_s)}</div>
          </div>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <${MetricPill} label="Gen" value=${keeper.generation ?? 0} />
        <${MetricPill} label="Turn" value=${keeper.turn_count ?? 0} />
        <${MetricPill} label="Tool" value=${toolCount > 0 ? toolCount : '-'} />
        ${keeper.runtime_blocker_class || keeper.last_blocker
          ? html`<${MetricPill} label="Blocker" value="yes" tone="warn" />`
          : null}
        ${summary.band.key === 'paused' ? html`<${MetricPill} label="Pause" value="on" tone="paused" />` : null}
      </div>
    </button>
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
        ${totalTools > 0 ? html`<${MetricPill} label="도구 호출" value=${totalTools} />` : null}
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

  const sorted = [...allKeepers].sort((left, right) => {
    const leftSummary = summarizeKeeperMonitoring(left)
    const rightSummary = summarizeKeeperMonitoring(right)
    const rank = { attention: 0, active: 1, paused: 2, offline: 3 }
    if (rank[leftSummary.band.key] !== rank[rightSummary.band.key]) {
      return rank[leftSummary.band.key] - rank[rightSummary.band.key]
    }
    return (left.last_activity_ago_s ?? Number.POSITIVE_INFINITY) - (right.last_activity_ago_s ?? Number.POSITIVE_INFINITY)
  })

  return html`
    <section class="monitor-surface-card monitor-surface-card-medium mb-6 p-4 md:p-5">
      <div class="flex flex-col gap-4">
        <div class="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
          <div class="min-w-0">
            <div class="text-[11px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">Keeper 운영판</div>
            <h3 class="m-0 mt-1 text-[18px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">먼저 볼 것은 state가 아니라 운영 상태입니다</h3>
            <p class="m-0 mt-2 max-w-[720px] text-[12px] leading-[1.6] text-[var(--text-body)]">
              가동중, 주의 필요, 일시정지, 오프라인은 운영 우선순위이고, 그 아래의 phase와 stage는 왜 그런지 설명하는 근거입니다.
            </p>
          </div>
        </div>

        <${FleetSummary} keepers=${allKeepers} />

        <div class="grid gap-3">
          ${sorted.map(keeper => html`<${KeeperRow} key=${keeper.name} keeper=${keeper} />`)}
        </div>
      </div>
    </section>
  `
}
