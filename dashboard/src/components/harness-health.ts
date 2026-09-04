// Safety Harness panel — evaluator calibration and long-running runtime rails.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
// The goal tree is already loaded for the goals screen; the aim shown beside a
// verdict is read from it rather than fetched again here.
import { goalTreeData } from '../goal-tree-state'
import { formatPct1 } from '../lib/format-number'
import { formatTimestampKo } from '../lib/format-time'
import { assertExhaustive } from '../lib/exhaustive'
import { SectionCard } from './common/card'
import { SectionCap } from './common/section-cap'
import { MermaidGraph } from './common/mermaid-graph'
import { KpiStripView, type KpiStripViewData } from './kpi-strip-view'
import {
  harness,
  loadHarnessHealth,
  clearHarnessReloadTimer,
  handleHarnessSSE,
} from './harness-health-state'
import type {
  RailStatus,
  HarnessHealthData,
} from './harness-health-state'
import {
  railStatusLabel,
  freshnessLabel,
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
  goalsByTaskFromTree,
} from './harness-health-sections'

// ── Mermaid flow helpers (live state graph) ──
// Mermaid classDef requires literal hex values — CSS vars are not resolved.
// These constants map to design system token values for single-source truth.

/* Mermaid classDef colors cannot reference CSS vars, so the dark-fantasy
   palette is mirrored here as literals (dashboard is dark-only). Keep these
   in sync with the _ds Dark-Fantasy tokens noted per line. */
const M_SOURCE_FILL = '#221815'     // --color-bg-3 (bruised meat)
const M_SOURCE_STROKE = '#5a3028'   // --color-line-2 (scab)
const M_SOURCE_TEXT = '#b8a488'     // --color-fg-2 (bandage)
const M_HUB_FILL = '#14100d'        // --color-bg-surface (rotted wood)
const M_HUB_STROKE = '#c4a265'      // brass accent (central hub)
const M_HUB_TEXT = '#e8d8b8'        // --color-fg-1 (bone)
const M_HEALTHY_FILL = '#16210f'    // bile-green bg
const M_HEALTHY_STROKE = '#5a7a3a'  // --status-ok (bile)
const M_HEALTHY_TEXT = '#9abc7a'    // --ok-fg
const M_WARN_FILL = '#2a1d08'       // ember bg
const M_WARN_STROKE = '#a06a1a'     // --status-warn (ember)
const M_WARN_TEXT = '#d49a3a'       // --warn-fg
const M_STALE_FILL = '#1b1612'      // --color-bg-2
const M_STALE_STROKE = '#6a5848'    // --color-fg-3 (mold dust)
const M_STALE_TEXT = '#b8a488'      // --color-fg-2
const M_IDLE_FILL = '#14100d'       // --color-bg-surface
const M_IDLE_STROKE = '#5a3028'     // --color-line-2
const M_IDLE_TEXT = '#6a5848'       // --color-fg-3
const M_ACTIVE_STROKE = '#c4a265'   // brass accent (active highlight)

type HarnessRailKey = 'evaluator'

function railTitle(rail: HarnessRailKey): string {
  switch (rail) {
    case 'evaluator':
      return '평가 모델'
  }
  return assertExhaustive(rail, 'HarnessRailKey')
}

function railEventAt(data: HarnessHealthData, rail: HarnessRailKey): number | null {
  switch (rail) {
    case 'evaluator':
      return data.overview.evaluator_last_event_at
  }
  return assertExhaustive(rail, 'HarnessRailKey')
}

function activeRail(data: HarnessHealthData): HarnessRailKey | null {
  const rails: HarnessRailKey[] = ['evaluator']
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

// See harness-health-sections.ts comment above railStatusLabel for why
// the `idle: default:` pattern is preserved on RailStatus consumers
// despite the FSM exhaustive-match anti-pattern: wire data arrives via
// type assertion at the API boundary, so the default is load-bearing
// until a `membershipParse<RailStatus>` boundary parser RFC lands.
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
    `  evaluator["${flowNodeLabel('평가 모델', data.overview.evaluator_status, railDetail(data, 'evaluator'), railFreshness(data, 'evaluator'))}"]`,
    '  readModel["하네스 데이터<br/>/api/v1/dashboard/harness-health"]',
    '  labUi["Lab / 안전 감시<br/>실시간 상태"]',
    '  taskDone -->|"판정 기록"| evaluator',
    '  evaluator --> readModel',
    '  readModel --> labUi',
    '  labUi -. "debounced reload" .-> readModel',
    '  class taskDone,keeperTurn source;',
    `  class evaluator ${flowStatusClass(data.overview.evaluator_status)};`,
    '  class readModel,labUi hub;',
  ]
  if (currentRail === 'evaluator') source.push('  class evaluator activeRail;')
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
            작업 완료 판정이 하네스로 모이는 구조입니다.
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
        <div class="v2-lab-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4">
          <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div class="max-w-3xl">
              <${SectionCap}>keeper 장기 실행 중 평가 판정이 정상인지 감시합니다<//>
              <div class="mt-2 text-2xl font-semibold text-[var(--color-fg-secondary)]">${heroTitle(data)}</div>
              <div class="mt-2 text-sm leading-airy text-[var(--color-fg-primary)]">${heroBody(data)}</div>
            </div>
            <div class="flex items-center gap-2">
              <button
                type="button"
                class="v2-lab-action rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2.5 py-1 text-2xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-accent-fg)] hover:text-[var(--color-fg-primary)]"
                onClick=${() => { void loadHarnessHealth() }}
              >새로고침</button>
            </div>
          </div>

          <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-2">
            <${HeroRailCard}
              label="평가 모델"
              status=${data.overview.evaluator_status}
              detail=${railDetail(data, 'evaluator')}
              freshness=${railFreshness(data, 'evaluator')}
            />
          </div>

          <div class="mt-4 text-xs text-[var(--color-fg-disabled)]">
            generated ${formatTimestampKo(data.generated_at)} · 마지막 안전 신호 ${freshnessLabel(data.overview.last_signal_at)}
          </div>
        </div>

        <div class="v2-lab-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-4 py-3 text-sm leading-airy text-[var(--color-fg-primary)]">
          ${data.scope_note}
        </div>

        <${ScopePairing} />
      </div>
    `
  }

  return html`
    <div class="v2-lab-surface flex flex-col gap-4">
      <${SectionCard} label="안전 감시" class="section v2-lab-panel">
        ${overviewContent}
      <//>

      <${SectionCard} label="감시 흐름도" class="section v2-lab-panel">
        ${!data || !flowSource ? html`
          <${EmptySignal} text="감시 흐름 데이터 없음" />
        ` : html`
          <${HarnessFlowCard} data=${data} />
        `}
      <//>

      <${SectionCard} label="평가 모델 건강도" class="section">
        ${!data || !cal ? html`
          <${EmptySignal} text="평가 모델 데이터 없음" />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="평가 모델 건강도"
              description="keeper 출력을 채점하는 모델이 제대로 작동하는지 봅니다."
              status=${data.overview.evaluator_status}
              lastEventAt=${data.overview.evaluator_last_event_at}
            />

            ${fallbackPct > 80 ? html`
              <div class="v2-lab-panel rounded-[var(--r-1)] border border-[var(--warn-30)] bg-[var(--warn-12)] px-4 py-3">
                <div class="mb-1 text-sm font-medium text-[var(--color-status-warn)]">평가 모델 미연결</div>
                <div class="text-xs text-[var(--color-status-warn)]">
                  전체 ${cal.total_verdicts}건 중 ${fallbackCount}건이 대체 처리됐습니다.
                  지금은 평가 모델보다 기본 규칙이 더 많이 작동합니다.
                </div>
                ${fallbackReasons.length > 0 ? html`
                  <details class="v2-lab-detail mt-2">
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

            <${KpiStripView}
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
              ] satisfies KpiStripViewData['cells']}
            />

            <div class="v2-lab-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-xs leading-loose text-[var(--color-fg-muted)]">
              인간 라벨 ${cal.labeled_count}건이 calibration ground truth입니다. 값이 0이면 runtime health는 볼 수 있어도 evaluator accuracy는 아직 검증되지 않았습니다.
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--color-fg-disabled)]">게이트 분포</div>
              <${GateChart} distribution=${cal.gate_distribution} />
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--color-fg-disabled)]">최근 판정</div>
              <${RecentVerdictsList}
                items=${data.recent_verdicts}
                goalsByTask=${goalsByTaskFromTree(goalTreeData.value?.tree)}
              />
            </div>
          </div>
        `}
      <//>

    </div>
  `
}
