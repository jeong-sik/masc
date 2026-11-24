/**
 * Workspace 1: `1 Pulse` (`/pulse`)
 *
 * - 4-KPI Hero Strip (`Active Keepers`, `Tasks Done/24h & Verify`, `Turns/24h`,
 *   `Spend/24h ($0 Sub / $0 Exhausted / ? Unreported)`), zero orphan 7th card,
 *   zero empty `0.000 Candle` box.
 * - Attention Queue Card (pending Approvals / Keeper Asks / Failed Keepers).
 * - Company Fleet 24h Sparklines (`uPlot` synced to global `timeWindow` + 28–36px portrait avatars).
 * - Lightweight Multi-Keeper Team Handoff & Succession Strip (zero Cytoscape).
 * - Active Goals + World Memory / Candle Pulse Digest linking into `/work/*` and `/knowledge/*`.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import {
  formatObserved,
  observedLoading,
  type Observed,
} from '../../core/resource-cache'
import {
  markViewSynced,
  subscribeObserverFrames,
} from '../../core/observer'
import {
  timeWindow,
  type TimeWindow,
} from '../../core/time-window'
import { currentSessionEpoch } from '../../core/auth'
import { KeeperBadge } from '../../components/keeper-badge'
import { UPlotChart, type UPlotSeriesSpec } from '../../components/primitives/uplot-chart'
import type { WorkspaceViewProps } from '../types'
import { loadPulseBundle, type PulseLoadBundle } from './pulse-data'
import {
  buildAttentionQueue,
  buildCompanyFleetGroups,
  buildPulseKpis,
  buildTeamHandoffPulse,
  formatCompactCount,
  formatMilliCandle,
  formatRelativeAge,
  isKeeperActive,
  isKeeperFailing,
  observeKeeperContextPct,
} from './pulse-model'
import type {
  PulseAttentionItem,
  PulseGoalSummary,
  PulseKeeperRow,
} from './types'
import './pulse.css'

const SPARKLINE_SERIES: readonly UPlotSeriesSpec[] = [
  {
    label: 'Turns',
    colorToken: '--brass-1',
    width: 1.75,
    fillAlpha: 0.16,
  },
]

function initialBundle(): PulseLoadBundle {
  return {
    shell: observedLoading(),
    keepers: observedLoading(),
    costs: observedLoading(),
    usage: observedLoading(),
    approvals: observedLoading(),
    asks: observedLoading(),
    goals: observedLoading(),
    board: observedLoading(),
    worldMemory: observedLoading(),
    candle: observedLoading(),
  }
}

function goalPhaseTone(phase: string): 'ok' | 'warn' | 'bad' | 'info' | 'brass' | 'default' {
  const lower = phase.toLowerCase()
  if (lower === 'completed') return 'ok'
  if (lower === 'verifying' || lower === 'awaiting_confirmation') return 'brass'
  if (lower === 'blocked') return 'bad'
  if (lower === 'paused') return 'warn'
  if (lower === 'executing') return 'info'
  return 'default'
}

function keeperCtxTone(obs: Observed<number>): 'ok' | 'warn' | 'bad' | 'default' {
  if (obs.kind !== 'value') return 'default'
  if (obs.data >= 85) return 'bad'
  if (obs.data >= 65) return 'warn'
  return 'ok'
}

export function PulseWorkspace(props: WorkspaceViewProps) {
  const win: TimeWindow = timeWindow.value
  const [bundle, setBundle] = useState<PulseLoadBundle>(initialBundle)
  const [observedAtSec, setObservedAtSec] = useState<number>(() => Math.floor(Date.now() / 1000))
  const [refreshing, setRefreshing] = useState(false)

  const refresh = useCallback(async (reason: 'mount' | 'route' | 'sse' | 'manual') => {
    const startEpoch = currentSessionEpoch()
    if (reason === 'manual') setRefreshing(true)
    try {
      const next = await loadPulseBundle(timeWindow.peek(), reason)
      if (currentSessionEpoch() !== startEpoch) return
      setBundle(next)
      setObservedAtSec(Math.floor(Date.now() / 1000))
      markViewSynced()
    } finally {
      if (reason === 'manual') setRefreshing(false)
    }
  }, [])

  useEffect(() => {
    void refresh('mount')
  }, [win, refresh])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null
    const unsub = subscribeObserverFrames(() => {
      if (timer) return
      timer = setTimeout(() => {
        timer = null
        void refresh('sse')
      }, 450)
    })
    return () => {
      unsub()
      if (timer) clearTimeout(timer)
    }
  }, [refresh])

  const nowSec = observedAtSec

  const kpis = useMemo(
    () =>
      buildPulseKpis({
        shell: bundle.shell,
        keepers: bundle.keepers,
        costs: bundle.costs,
        usage: bundle.usage,
        window: win,
      }),
    [bundle.shell, bundle.keepers, bundle.costs, bundle.usage, win],
  )

  const keepersList: readonly PulseKeeperRow[] = bundle.keepers.kind === 'value' ? bundle.keepers.data : []
  const knownKeeperSet = useMemo(() => new Set(keepersList.map((k) => k.name)), [keepersList])

  const attentionItems = useMemo<readonly PulseAttentionItem[]>(
    () =>
      buildAttentionQueue({
        approvals: bundle.approvals.kind === 'value' ? bundle.approvals.data : [],
        asks: bundle.asks.kind === 'value' ? bundle.asks.data : [],
        keepers: keepersList,
        nowSec,
      }),
    [bundle.approvals, bundle.asks, keepersList, nowSec],
  )

  const fleetGroups = useMemo(
    () =>
      buildCompanyFleetGroups({
        keepers: keepersList,
        shellGroups: bundle.shell.kind === 'value' ? bundle.shell.data.groups : [],
        window: win,
        nowSec,
      }),
    [keepersList, bundle.shell, win, nowSec],
  )

  const handoffs = useMemo(
    () =>
      buildTeamHandoffPulse(
        bundle.board.kind === 'value' ? bundle.board.data : [],
        keepersList,
        8,
      ),
    [bundle.board, keepersList],
  )

  const activeGoals = useMemo<readonly PulseGoalSummary[]>(() => {
    if (bundle.goals.kind !== 'value') return []
    return bundle.goals.data
      .filter((g) => {
        const p = g.phase.toLowerCase()
        return p !== 'completed' && p !== 'dropped'
      })
      .slice(0, 6)
  }, [bundle.goals])

  const candleDigest = bundle.candle.kind === 'value' ? bundle.candle.data : null
  const showCandleBalance =
    candleDigest !== null
    && candleDigest.policy_configuration === 'enabled'
    && (candleDigest.total_events > 0 || candleDigest.circulating_milli !== '0')

  const worldMemory = bundle.worldMemory.kind === 'value' ? bundle.worldMemory.data : null

  return html`
    <div class="pulse-root" data-workspace="pulse">
      <header class="pulse-header">
        <div class="pulse-header-title">
          <span class="ov-eyebrow">1 PULSE · OPERATIONS OVERVIEW</span>
          <h1>Fleet Pulse</h1>
        </div>
        <div class="pulse-header-meta">
          <button
            type="button"
            class="btn-ghost"
            disabled=${refreshing}
            onClick=${() => void refresh('manual')}
          >
            ${refreshing ? '갱신 중…' : '새로고침'}
          </button>
        </div>
      </header>

      <!-- 4-KPI Hero Strip -->
      <section class="pulse-kpis" aria-label="핵심 지표">
        ${kpis.map((kpi) => {
          const text = formatObserved(kpi.value)
          const isAbsent = kpi.value.kind === 'absent' || kpi.value.kind === 'unreported'
          return html`
            <button
              key=${kpi.id}
              type="button"
              class="pulse-kpi"
              data-kpi-id=${kpi.id}
              title=${kpi.exactTooltip ?? text}
              onClick=${() => props.onNavigate(kpi.route)}
            >
              <span class="pulse-kpi-label">${kpi.label}</span>
              <span
                class="pulse-kpi-value tnum"
                data-tone=${kpi.tone}
                data-absent=${isAbsent ? 'true' : 'false'}
              >
                ${text}
              </span>
              <span class="pulse-kpi-sub">${kpi.secondary ?? '상세 보기 →'}</span>
            </button>
          `
        })}
      </section>

      <div class="pulse-grid">
        <div class="pulse-col">
          <!-- Company Fleet 24h Sparklines -->
          <section class="pulse-card" aria-label="회사별 Keeper 플릿">
            <div class="pulse-card-head">
              <h2>Company Fleet · 24h Activity</h2>
              <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/keepers')}>
                전체 Keeper →
              </button>
            </div>
            ${bundle.keepers.kind === 'loading'
              ? html`<div class="pulse-empty">플릿 상태 불러오는 중…</div>`
              : bundle.keepers.kind === 'failed'
                ? html`<div class="ap-error" role="alert">플릿 조회 실패: ${bundle.keepers.error.message}</div>`
                : fleetGroups.length === 0
                  ? html`<div class="pulse-empty">등록된 Keeper 없음</div>`
                  : html`
                      <div class="pulse-fleet-groups">
                        ${fleetGroups.map((group) => {
                          const turnFmt = formatCompactCount(group.turnsInWindow)
                          return html`
                            <article key=${group.company} class="pulse-fleet-group">
                              <div class="pulse-fleet-group-head">
                                <span class="pulse-fleet-group-name">${group.company}</span>
                                <div class="pulse-header-meta">
                                  <span class="pulse-pill" data-tone=${group.activeCount > 0 ? 'ok' : 'default'}>
                                    ${group.activeCount}/${group.keepers.length} active
                                  </span>
                                  ${group.failingCount > 0 && html`
                                    <span class="pulse-pill" data-tone="bad">
                                      ⚠ ${group.failingCount} fault
                                    </span>
                                  `}
                                  <span class="pulse-pill" data-tone="brass" title=${`정확한 24h 턴 수: ${turnFmt.exact}`}>
                                    ${turnFmt.short} turns/24h
                                  </span>
                                </div>
                              </div>

                              <div class="pulse-keeper-grid">
                                ${group.keepers.map((k) => {
                                  const ctxObs = observeKeeperContextPct(k)
                                  const ctxText = formatObserved(ctxObs, (v) => `${v}%`)
                                  const active = isKeeperActive(k)
                                  const failing = isKeeperFailing(k)
                                  return html`
                                    <button
                                      key=${k.name}
                                      type="button"
                                      class="pulse-keeper-tile"
                                      onClick=${() => props.onNavigate(`/keepers/${encodeURIComponent(k.name)}/chat`)}
                                    >
                                      <div class="pulse-keeper-tile-left">
                                        <${KeeperBadge}
                                          id=${k.name}
                                          size="md"
                                          variant="sigil"
                                          portrait=${true}
                                          beat=${active}
                                        />
                                        <div class="pulse-keeper-tile-meta">
                                          <span class="pulse-keeper-tile-name">${k.name}</span>
                                          <span class="pulse-keeper-tile-sub">
                                            ${failing ? `⚠ ${k.health}` : k.paused ? 'paused' : k.phase}
                                          </span>
                                        </div>
                                      </div>
                                      <span
                                        class="pulse-pill"
                                        data-tone=${keeperCtxTone(ctxObs)}
                                        title=${k.context_tokens != null && k.context_max != null
                                          ? `${k.context_tokens.toLocaleString('en-US')} / ${k.context_max.toLocaleString('en-US')} tok`
                                          : 'Context 비율'}
                                      >
                                        Ctx ${ctxText}
                                      </span>
                                    </button>
                                  `
                                })}
                              </div>

                              <div class="pulse-spark-wrap">
                                <${UPlotChart}
                                  id=${`pulse-spark-${group.company}`}
                                  title=${`${group.company} · 24h 턴 추이`}
                                  data=${group.sparklineData}
                                  series=${SPARKLINE_SERIES}
                                  height=${92}
                                  syncCrosshair=${true}
                                  emptyLabel="해당 구간 턴 기록 없음"
                                />
                              </div>
                            </article>
                          `
                        })}
                      </div>
                    `}
          </section>

          <!-- Multi-Keeper Team Handoff & Succession Strip (Zero Cytoscape) -->
          <section class="pulse-card" aria-label="팀 핸드오프 및 협업 펄스">
            <div class="pulse-card-head">
              <h2>Team Handoff & Succession Pulse</h2>
              <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/knowledge/board')}>
                Board 열기 →
              </button>
            </div>
            ${handoffs.length === 0
              ? html`<div class="pulse-empty">최근 다중 Keeper 핸드오프/승계 신호 없음</div>`
              : html`
                  <div class="pulse-handoff-list">
                    ${handoffs.map((h) => html`
                      <button
                        key=${h.id}
                        type="button"
                        class="pulse-handoff-row"
                        onClick=${() => props.onNavigate(h.route)}
                      >
                        <${KeeperBadge} id=${h.fromKeeper} size="sm" portrait=${knownKeeperSet.has(h.fromKeeper)} />
                        ${h.toKeepers.length > 0 && html`
                          <span class="pulse-handoff-arrow" aria-hidden="true">
                            ${h.kind === 'succession' ? '⇒' : '→'}
                          </span>
                          ${h.toKeepers.map((target) => html`
                            <${KeeperBadge} key=${target} id=${target} size="sm" portrait=${knownKeeperSet.has(target)} />
                          `)}
                        `}
                        <span class="pulse-handoff-title">${h.title}</span>
                        <span class="pulse-pill" data-tone=${h.kind === 'succession' ? 'brass' : 'info'}>
                          ${h.kind === 'succession' ? 'Succession' : h.kind === 'handoff' ? 'Handoff' : `${h.replyCount} replies`}
                        </span>
                      </button>
                    `)}
                  </div>
                `}
          </section>
        </div>

        <div class="pulse-col">
          <!-- Attention Queue Card -->
          <section class="pulse-card" aria-label="주의 필요 대기열">
            <div class="pulse-card-head">
              <h2>Attention Queue</h2>
              <div class="pulse-header-meta">
                <span class="pulse-pill" data-tone=${attentionItems.length > 0 ? 'warn' : 'ok'}>
                  ${attentionItems.length}건
                </span>
                <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/work/inbox')}>
                  Inbox →
                </button>
              </div>
            </div>
            ${attentionItems.length === 0
              ? html`<div class="pulse-empty">대기 중인 승인·질문·오류 없음</div>`
              : html`
                  <div class="pulse-attn-list">
                    ${attentionItems.slice(0, 10).map((item) => html`
                      <div key=${item.id} class="pulse-attn-row" data-sev=${item.severity}>
                        <div class="pulse-attn-main">
                          <span class="pulse-attn-title">
                            ${item.severity === 'critical' ? '⚠ ' : ''}${item.title}
                          </span>
                          <span class="pulse-attn-detail">${item.keeper} · ${item.detail}</span>
                        </div>
                        <div class="pulse-attn-actions">
                          <span class="pulse-pill">${formatRelativeAge(item.ageSec)}</span>
                          <button
                            type="button"
                            class="btn-ghost"
                            onClick=${() => props.onInspect({
                              title: item.title,
                              subtitle: item.keeper,
                              kind: item.kind,
                              data: item.raw,
                            })}
                          >
                            미리보기
                          </button>
                          <button
                            type="button"
                            class="btn-primary"
                            onClick=${() => props.onNavigate(item.route)}
                          >
                            이동
                          </button>
                        </div>
                      </div>
                    `)}
                  </div>
                `}
          </section>

          <!-- Active Goals -->
          <section class="pulse-card" aria-label="진행 중인 Goals">
            <div class="pulse-card-head">
              <h2>Active Goals</h2>
              <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/work/goals')}>
                Goals →
              </button>
            </div>
            ${bundle.goals.kind === 'loading'
              ? html`<div class="pulse-empty">Goal 목록 불러오는 중…</div>`
              : activeGoals.length === 0
                ? html`<div class="pulse-empty">활성 Goal 없음</div>`
                : html`
                    <div class="pulse-goal-list">
                      ${activeGoals.map((g) => html`
                        <button
                          key=${g.id}
                          type="button"
                          class="pulse-goal-row"
                          onClick=${() => props.onNavigate('/work/goals')}
                        >
                          <span class="pulse-goal-title" title=${g.title}>${g.title}</span>
                          <div class="pulse-goal-badges">
                            <span class="pulse-pill" data-tone=${goalPhaseTone(g.phase)} title=${g.phase}>
                              ${g.phase}
                            </span>
                            <span class="pulse-pill">
                              ${g.task_done_count}/${g.task_count}
                            </span>
                            ${g.awaiting_verification_count > 0 && html`
                              <span class="pulse-pill" data-tone="warn">
                                검증 ${g.awaiting_verification_count}
                              </span>
                            `}
                          </div>
                        </button>
                      `)}
                    </div>
                  `}
          </section>

          <!-- World Memory & Candle Pulse Digest -->
          <section class="pulse-card" aria-label="World Memory 및 Candle 요약">
            <div class="pulse-card-head">
              <h2>World Memory & Candle Digest</h2>
            </div>
            <div class="pulse-digest-grid">
              <div class="pulse-digest-box">
                <div class="pulse-card-head">
                  <h2>World Memory</h2>
                  <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/knowledge/memory')}>
                    Memory →
                  </button>
                </div>
                ${worldMemory === null
                  ? html`<div class="pulse-empty">${formatObserved(bundle.worldMemory)}</div>`
                  : html`
                      <div class="pulse-kv-grid">
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Claims</span>
                          <span class="pulse-kv-v">${formatCompactCount(worldMemory.claims_count).short}</span>
                        </div>
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Facts</span>
                          <span class="pulse-kv-v">${formatCompactCount(worldMemory.facts_count).short}</span>
                        </div>
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Conflicts</span>
                          <span class="pulse-kv-v">${worldMemory.conflicts_count}</span>
                        </div>
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Wiki Pages</span>
                          <span class="pulse-kv-v">
                            ${worldMemory.wiki_count !== null ? worldMemory.wiki_count : '없음'}
                          </span>
                        </div>
                      </div>
                    `}
              </div>

              <div class="pulse-digest-box" data-accent=${showCandleBalance ? 'brass' : undefined}>
                <div class="pulse-card-head">
                  <h2>Candle Economy</h2>
                  <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/work/candle')}>
                    Candle →
                  </button>
                </div>
                ${candleDigest === null
                  ? html`<div class="pulse-empty">${formatObserved(bundle.candle)}</div>`
                  : !showCandleBalance
                    ? html`
                        <div class="pulse-empty">
                          ${candleDigest.policy_configuration === 'enabled'
                            ? '발행된 Candle 원장 기록 없음'
                            : `Candle 정책 비활성 (${candleDigest.policy_configuration}${candleDigest.disabled_reason ? `: ${candleDigest.disabled_reason}` : ''})`}
                        </div>
                      `
                    : html`
                        <div class="pulse-kv-grid">
                          <div class="pulse-kv">
                            <span class="pulse-kv-k">Circulating</span>
                            <span class="pulse-kv-v">
                              ${formatObserved(formatMilliCandle(candleDigest.circulating_milli))} C
                            </span>
                          </div>
                          <div class="pulse-kv">
                            <span class="pulse-kv-k">Holders</span>
                            <span class="pulse-kv-v">${candleDigest.active_keepers}</span>
                          </div>
                          <div class="pulse-kv">
                            <span class="pulse-kv-k">Events</span>
                            <span class="pulse-kv-v">${candleDigest.total_events}</span>
                          </div>
                          <div class="pulse-kv">
                            <span class="pulse-kv-k">Half-life</span>
                            <span class="pulse-kv-v">
                              ${candleDigest.half_life_hours !== null ? `${candleDigest.half_life_hours}h` : '없음'}
                            </span>
                          </div>
                        </div>
                      `}
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
  `
}

export default PulseWorkspace
