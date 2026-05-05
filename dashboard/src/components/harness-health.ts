// Safety Harness panel — evaluator calibration and long-running runtime rails.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { navigate } from '../router'
import { formatPct1 } from '../lib/format-number'
import { Card } from './common/card'
import { SectionCap } from './common/section-cap'
import { MermaidGraph } from './common/mermaid-graph'
import { KpiStripIsland, type KpiStripIslandData } from './kpi-strip-island'
import {
  harness,
  loadHarnessHealth,
  clearHarnessReloadTimer,
  handleHarnessSSE,
  resetHarnessHealthState,
  refreshHarnessSurface,
} from './harness-health-state'
import type {
  RailStatus,
  HarnessHealthData,
} from './harness-health-state'
import {
  railStatusLabel,
  freshnessLabel,
  formatTimestamp,
  heroTitle,
  heroBody,
  railDetail,
  railFreshness,
  EmptySignal,
  HeroRailCard,
  ScopePairing,
  RailHeader,
  GateChart,
  RecentVerdictsList,
  PreCompactList,
  HandoffList,
} from './harness-health-sections'

export { resetHarnessHealthState, refreshHarnessSurface }

// ── Mermaid flow helpers (live state graph) ──
// Mermaid classDef requires literal hex values — CSS vars are not resolved.
// These constants map to design system token values for single-source truth.

const M_SOURCE_FILL = '#0f172a'     // --color-bg-3 (navy approx)
const M_SOURCE_STROKE = '#475569'   // --color-line-2
const M_SOURCE_TEXT = '#cbd5e1'     // --color-frost-100
const M_HUB_FILL = '#111827'        // --color-bg-surface
const M_HUB_STROKE = '#38bdf8'      // --color-cyan
const M_HUB_TEXT = '#e0f2fe'        // --color-frost-100
const M_HEALTHY_FILL = '#082f1d'
const M_HEALTHY_STROKE = '#4ade80'
const M_HEALTHY_TEXT = '#dcfce7'
const M_WARN_FILL = '#3b2a07'
const M_WARN_STROKE = '#fbbf24'
const M_WARN_TEXT = '#fde68a'
const M_STALE_FILL = '#1f2937'
const M_STALE_STROKE = '#94a3b8'    // --color-fg-4
const M_STALE_TEXT = '#e2e8f0'      // --color-frost-100
const M_IDLE_FILL = '#111827'       // --color-bg-surface
const M_IDLE_STROKE = '#475569'     // --color-line-2
const M_IDLE_TEXT = '#94a3b8'       // --color-fg-4
const M_ACTIVE_STROKE = '#7dd3fc'

type HarnessRailKey = 'evaluator' | 'pre_compact' | 'handoff'

function railTitle(rail: HarnessRailKey): string {
  switch (rail) {
    case 'evaluator':
      return '평가 모델'
    case 'pre_compact':
      return '압축 전 상태'
    case 'handoff':
    default:
      return '세대 교체'
  }
}

function railEventAt(data: HarnessHealthData, rail: HarnessRailKey): number | null {
  switch (rail) {
    case 'evaluator':
      return data.overview.evaluator_last_event_at
    case 'pre_compact':
      return data.overview.pre_compact_last_event_at
    case 'handoff':
    default:
      return data.overview.handoff_last_event_at
  }
}

function activeRail(data: HarnessHealthData): HarnessRailKey | null {
  const rails: HarnessRailKey[] = ['evaluator', 'pre_compact', 'handoff']
  return rails.reduce<HarnessRailKey | null>((current, rail) => {
    if (!current) return railEventAt(data, rail) == null ? null : rail
    const currentTs = railEventAt(data, current) ?? Number.NEGATIVE_INFINITY
    const nextTs = railEventAt(data, rail) ?? Number.NEGATIVE_INFINITY
    return nextTs > currentTs ? rail : current
  }, null)
}

function escapeMermaidLabel(value: string): string {
  return value
    .replace(/"/g, '\'')
    .replace(/[[\]{}()|#;]/g, ' ')
    .replace(/\n+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim()
}

function flowNodeLabel(title: string, status: RailStatus, detail: string, freshness: string): string {
  return escapeMermaidLabel(`${title}<br/>${railStatusLabel(status)}<br/>${detail}<br/>최근 ${freshness}`)
}

function flowStatusClass(status: RailStatus): string {
  switch (status) {
    case 'healthy':
      return 'healthyRail'
    case 'warning':
      return 'warningRail'
    case 'stale':
      return 'staleRail'
    case 'idle':
    default:
      return 'idleRail'
  }
}

function flowSummaryLine(title: string, status: RailStatus, detail: string, freshness: string): string {
  return `${title}: ${railStatusLabel(status)} · ${detail} · 최근 ${freshness}`
}

function flowFallbackSummary(data: HarnessHealthData): string {
  return [
    flowSummaryLine(
      '평가 모델',
      data.overview.evaluator_status,
      railDetail(data, 'evaluator'),
      railFreshness(data, 'evaluator'),
    ),
    flowSummaryLine(
      '압축 전 상태',
      data.overview.pre_compact_status,
      railDetail(data, 'pre_compact'),
      railFreshness(data, 'pre_compact'),
    ),
    flowSummaryLine(
      '세대 교체',
      data.overview.handoff_status,
      railDetail(data, 'handoff'),
      railFreshness(data, 'handoff'),
    ),
  ].join(' | ')
}

export function buildHarnessFlowMermaid(data: HarnessHealthData): string {
  const currentRail = activeRail(data)
  const source = [
    'flowchart LR',
    `  classDef source fill:${M_SOURCE_FILL},stroke:${M_SOURCE_STROKE},color:${M_SOURCE_TEXT};`,
    `  classDef hub fill:${M_HUB_FILL},stroke:${M_HUB_STROKE},color:${M_HUB_TEXT};`,
    `  classDef healthyRail fill:${M_HEALTHY_FILL},stroke:${M_HEALTHY_STROKE},color:${M_HEALTHY_TEXT};`,
    `  classDef warningRail fill:${M_WARN_FILL},stroke:${M_WARN_STROKE},color:${M_WARN_TEXT};`,
    `  classDef staleRail fill:${M_STALE_FILL},stroke:${M_STALE_STROKE},color:${M_STALE_TEXT},stroke-dasharray: 5 3;`,
    `  classDef idleRail fill:${M_IDLE_FILL},stroke:${M_IDLE_STROKE},color:${M_IDLE_TEXT},stroke-dasharray: 3 4;`,
    `  classDef activeRail stroke:${M_ACTIVE_STROKE},stroke-width:3px;`,
    '  taskDone["작업 완료<br/>판정 검증"]',
    '  keeperTurn["keeper 턴<br/>압축 압력"]',
    '  keeperRollover["keeper 교체<br/>지표 스냅샷"]',
    `  evaluator["${flowNodeLabel('평가 모델', data.overview.evaluator_status, railDetail(data, 'evaluator'), railFreshness(data, 'evaluator'))}"]`,
    `  preCompact["${flowNodeLabel('압축 전 상태', data.overview.pre_compact_status, railDetail(data, 'pre_compact'), railFreshness(data, 'pre_compact'))}"]`,
    `  handoff["${flowNodeLabel('세대 교체', data.overview.handoff_status, railDetail(data, 'handoff'), railFreshness(data, 'handoff'))}"]`,
    '  readModel["하네스 데이터<br/>/api/v1/dashboard/harness-health"]',
    '  labUi["Lab / 안전 감시<br/>실시간 상태"]',
    '  taskDone -->|"판정 기록"| evaluator',
    '  keeperTurn -->|"압축 신호"| preCompact',
    '  keeperRollover -->|"교체 신호"| handoff',
    '  evaluator --> readModel',
    '  preCompact --> readModel',
    '  handoff --> readModel',
    '  readModel --> labUi',
    '  labUi -. "debounced reload" .-> readModel',
    '  class taskDone,keeperTurn,keeperRollover source;',
    `  class evaluator ${flowStatusClass(data.overview.evaluator_status)};`,
    `  class preCompact ${flowStatusClass(data.overview.pre_compact_status)};`,
    `  class handoff ${flowStatusClass(data.overview.handoff_status)};`,
    '  class readModel,labUi hub;',
  ]
  if (currentRail === 'evaluator') source.push('  class evaluator activeRail;')
  if (currentRail === 'pre_compact') source.push('  class preCompact activeRail;')
  if (currentRail === 'handoff') source.push('  class handoff activeRail;')
  return source.join('\n')
}

function HarnessFlowCard({ data }: { data: HarnessHealthData }) {
  const source = buildHarnessFlowMermaid(data)
  const active = activeRail(data)
  const fallbackText = flowFallbackSummary(data)

  return html`
    <div class="space-y-3">
      <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
        <div>
          <div class="text-sm font-medium text-[var(--color-fg-secondary)]">실시간 상태 그래프</div>
          <div class="mt-1 text-sm leading-loose text-[var(--color-fg-muted)]">
            작업 완료, 컨텍스트 압축, 세대 교체 신호가 하네스로 모이는 구조입니다.
          </div>
        </div>
        <div class="text-xs text-[var(--color-fg-disabled)]">
          가장 최근 채널: ${active ? railTitle(active) : '없음'}
        </div>
      </div>

      <div class="flex flex-wrap gap-2 text-2xs text-[var(--color-fg-disabled)]">
        <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-1">실선: 실시간 신호</span>
        <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-1">점선: 스냅샷 갱신</span>
        <span class="rounded-[var(--r-0)] border border-[var(--color-accent-fg)] px-2 py-1 text-[var(--color-fg-primary)]">강조: 가장 최근 채널</span>
      </div>

      <${MermaidGraph}
        source=${source}
        prefix="harness-flow"
        fallbackText=${fallbackText}
        minHeightClass="min-h-65"
        diagramClass="border border-[var(--color-border-default)]"
      />
    </div>
  `
}

export function HarnessHealth() {
  useEffect(() => {
    void loadHarnessHealth()
    return () => {
      clearHarnessReloadTimer()
    }
  }, [])
  useEffect(() => {
    const unsubscribe = handleHarnessSSE()
    return () => {
      unsubscribe()
    }
  }, [])

  const s = harness.state.value
  const data = s.status === 'loaded' ? s.data : undefined
  const cal = data?.calibration
  const rejectRate = cal && cal.total_verdicts > 0
    ? formatPct1(cal.reject_count / cal.total_verdicts)
    : '0'
  const agreementPct = cal ? formatPct1(cal.agreement_rate) : '-'
  const fallbackCount = cal?.fallback_count ?? 0
  const fallbackPct = data ? Math.round((data.overview.fallback_ratio ?? 0) * 100) : 0
  const fallbackReasons = cal?.recent_fallback_reasons ?? []
  const flowSource = data ? buildHarnessFlowMermaid(data) : null
  const isLoading = s.status === 'loading' || s.status === 'idle'
  const isError = s.status === 'error'
  let overviewContent = html`<${EmptySignal} text="안전 감시 데이터가 없습니다." />`

  if (isLoading) {
    overviewContent = html`<div class="text-sm text-[var(--color-fg-disabled)]" role="status">로딩 중...</div>`
  } else if (isError) {
    overviewContent = html`<div class="text-sm text-[var(--color-status-err)]" role="alert">${s.message}</div>`
  } else if (data) {
    overviewContent = html`
      <div class="space-y-4">
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4">
          <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div class="max-w-3xl">
              <${SectionCap}>keeper 장기 실행 중 평가/압축/교체가 정상인지 감시합니다<//>
              <div class="mt-2 text-2xl font-semibold text-[var(--color-fg-secondary)]">${heroTitle(data)}</div>
              <div class="mt-2 text-sm leading-airy text-[var(--color-fg-primary)]">${heroBody(data)}</div>
            </div>
            <div class="flex items-center gap-2">
              <button
                type="button"
                class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2.5 py-1 text-2xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-accent-fg)] hover:text-[var(--color-fg-primary)]"
                onClick=${() => { void loadHarnessHealth() }}
              >새로고침</button>
              <button
                type="button"
                class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2.5 py-1 text-2xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--ok-30)] hover:text-[var(--color-fg-primary)]"
                onClick=${() => navigate('lab', { section: 'autoresearch' })}
              >오토리서치 보기</button>
            </div>
          </div>

          <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-3">
            <${HeroRailCard}
              label="평가 모델"
              status=${data.overview.evaluator_status}
              detail=${railDetail(data, 'evaluator')}
              freshness=${railFreshness(data, 'evaluator')}
            />
            <${HeroRailCard}
              label="압축 전 상태"
              status=${data.overview.pre_compact_status}
              detail=${railDetail(data, 'pre_compact')}
              freshness=${railFreshness(data, 'pre_compact')}
            />
            <${HeroRailCard}
              label="세대 교체"
              status=${data.overview.handoff_status}
              detail=${railDetail(data, 'handoff')}
              freshness=${railFreshness(data, 'handoff')}
            />
          </div>

          <div class="mt-4 text-xs text-[var(--color-fg-disabled)]">
            generated ${formatTimestamp(data.generated_at)} · 마지막 안전 신호 ${freshnessLabel(data.overview.last_signal_at)}
          </div>
        </div>

        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-4 py-3 text-sm leading-airy text-[var(--color-fg-primary)]">
          ${data.scope_note}
        </div>

        <${ScopePairing} />
      </div>
    `
  }

  return html`
    <div class="space-y-4">
      <${Card} title="안전 감시" class="section">
        ${overviewContent}
      <//>

      <${Card} title="감시 흐름도" class="section">
        ${!data || !flowSource ? html`
          <${EmptySignal} text="감시 흐름 데이터가 없습니다." />
        ` : html`
          <${HarnessFlowCard} data=${data} />
        `}
      <//>

      <${Card} title="평가 모델 건강도" class="section">
        ${!data || !cal ? html`
          <${EmptySignal} text="평가 모델 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="평가 모델 건강도"
              description="keeper 출력을 채점하는 모델이 제대로 작동하는지 봅니다."
              status=${data.overview.evaluator_status}
              lastEventAt=${data.overview.evaluator_last_event_at}
            />

            ${fallbackPct > 80 ? html`
              <div class="rounded-[var(--r-1)] border border-[var(--warn-30)] bg-[var(--warn-12)] px-4 py-3">
                <div class="mb-1 text-sm font-medium text-[var(--color-status-warn)]">평가 모델 미연결</div>
                <div class="text-xs text-[var(--color-status-warn)]">
                  전체 ${cal.total_verdicts}건 중 ${fallbackCount}건이 대체 처리됐습니다.
                  지금은 평가 모델보다 기본 규칙이 더 많이 작동합니다.
                </div>
                ${fallbackReasons.length > 0 ? html`
                  <details class="mt-2">
                    <summary class="cursor-pointer text-xs text-[var(--color-status-warn)] opacity-70">최근 에러 (${fallbackReasons.length}건)</summary>
                    <div class="mt-1 space-y-1">
                      ${fallbackReasons.map(reason => html`
                        <div class="break-all font-mono text-xs text-[var(--color-status-warn)] opacity-70">${reason}</div>
                      `)}
                    </div>
                  </details>
                ` : null}
              </div>
            ` : null}

            <${KpiStripIsland}
              ariaLabel="calibration 요약"
              cols=${4}
              cells=${[
                { variant: 'stacked', label: '총 판정', value: cal.total_verdicts },
                { variant: 'stacked', label: '거부율', value: `${rejectRate}%` },
                { variant: 'stacked', label: '대체 처리율', value: `${fallbackPct}%` },
                {
                  variant: 'stacked',
                  label: '일치율',
                  value: `${agreementPct}%`,
                  caption: `FP:${cal.false_positive_count} FN:${cal.false_negative_count}`,
                },
              ] satisfies KpiStripIslandData['cells']}
            />

            <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-xs leading-loose text-[var(--color-fg-muted)]">
              인간 라벨 ${cal.labeled_count}건이 calibration ground truth입니다. 값이 0이면 runtime health는 볼 수 있어도 evaluator accuracy는 아직 검증되지 않았습니다.
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--color-fg-disabled)]">게이트 분포</div>
              <${GateChart} distribution=${cal.gate_distribution} />
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--color-fg-disabled)]">최근 판정</div>
              <${RecentVerdictsList} items=${data.recent_verdicts} />
            </div>
          </div>
        `}
      <//>

      <${Card} title="압축 전 상태" class="section">
        ${!data ? html`
          <${EmptySignal} text="압축 전 상태 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="컨텍스트 압축 압력"
              description=${data.pre_compact.description}
              status=${data.pre_compact.status}
              lastEventAt=${data.pre_compact.last_event_at}
            />
            <${KpiStripIsland}
              ariaLabel="압축 전 상태 요약"
              variant="stacked"
              cells=${[
                {
                  variant: 'stacked',
                  label: '최근 컨텍스트 사용률',
                  value: data.overview.latest_pre_compact_ratio != null
                    ? `${Math.round(data.overview.latest_pre_compact_ratio * 100)}%`
                    : '-',
                  caption: `최근 ${data.pre_compact.total_recent}건`,
                },
                {
                  variant: 'stacked',
                  label: '최근 신호',
                  value: freshnessLabel(data.pre_compact.last_event_at),
                },
                {
                  variant: 'stacked',
                  label: '상태',
                  value: railStatusLabel(data.pre_compact.status),
                },
              ] satisfies KpiStripIslandData['cells']}
            />
            <${PreCompactList} section=${data.pre_compact} />
          </div>
        `}
      <//>

      <${Card} title="세대 교체 기록" class="section">
        ${!data ? html`
          <${EmptySignal} text="세대 교체 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="keeper 세대 교체"
              description=${data.recent_handoffs.description}
              status=${data.recent_handoffs.status}
              lastEventAt=${data.recent_handoffs.last_event_at}
            />
            <${KpiStripIsland}
              ariaLabel="세대 교체 요약"
              variant="stacked"
              cells=${[
                {
                  variant: 'stacked',
                  label: '최근 세대',
                  value: data.overview.latest_handoff_generation != null
                    ? `${data.overview.latest_handoff_generation}세대`
                    : '-',
                  caption: `최근 ${data.recent_handoffs.total_recent}건`,
                },
                {
                  variant: 'stacked',
                  label: '최근 신호',
                  value: freshnessLabel(data.recent_handoffs.last_event_at),
                },
                {
                  variant: 'stacked',
                  label: '상태',
                  value: railStatusLabel(data.recent_handoffs.status),
                },
              ] satisfies KpiStripIslandData['cells']}
            />
            <${HandoffList} section=${data.recent_handoffs} />
          </div>
        `}
      <//>
    </div>
  `
}
