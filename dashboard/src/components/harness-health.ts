// Safety Harness panel — evaluator calibration and long-running runtime rails.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { lastEvent } from '../sse'
import { navigate } from '../router'
import { Card } from './common/card'
import { MermaidGraph } from './common/mermaid-graph'
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
  StatCard,
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

type HarnessRailKey = 'evaluator' | 'pre_compact' | 'handoff'

function railTitle(rail: HarnessRailKey): string {
  switch (rail) {
    case 'evaluator':
      return 'Evaluator'
    case 'pre_compact':
      return 'Pre-Compaction'
    case 'handoff':
    default:
      return 'Handoff'
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
    .replace(/[\[\]{}()|#;]/g, ' ')
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
      'Evaluator',
      data.overview.evaluator_status,
      railDetail(data, 'evaluator'),
      railFreshness(data, 'evaluator'),
    ),
    flowSummaryLine(
      'Pre-Compaction',
      data.overview.pre_compact_status,
      railDetail(data, 'pre_compact'),
      railFreshness(data, 'pre_compact'),
    ),
    flowSummaryLine(
      'Handoff',
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
    '  classDef source fill:#0f172a,stroke:#475569,color:#cbd5e1;',
    '  classDef hub fill:#111827,stroke:#38bdf8,color:#e0f2fe;',
    '  classDef healthyRail fill:#082f1d,stroke:#4ade80,color:#dcfce7;',
    '  classDef warningRail fill:#3b2a07,stroke:#fbbf24,color:#fde68a;',
    '  classDef staleRail fill:#1f2937,stroke:#94a3b8,color:#e2e8f0,stroke-dasharray: 5 3;',
    '  classDef idleRail fill:#111827,stroke:#475569,color:#94a3b8,stroke-dasharray: 3 4;',
    '  classDef activeRail stroke:#7dd3fc,stroke-width:3px;',
    '  taskDone["Task completion<br/>anti-rationalization review"]',
    '  keeperTurn["Keeper turn<br/>continuity pressure"]',
    '  keeperRollover["Keeper rollover<br/>metrics snapshot"]',
    `  evaluator["${flowNodeLabel('Evaluator', data.overview.evaluator_status, railDetail(data, 'evaluator'), railFreshness(data, 'evaluator'))}"]`,
    `  preCompact["${flowNodeLabel('Pre-Compaction', data.overview.pre_compact_status, railDetail(data, 'pre_compact'), railFreshness(data, 'pre_compact'))}"]`,
    `  handoff["${flowNodeLabel('Handoff', data.overview.handoff_status, railDetail(data, 'handoff'), railFreshness(data, 'handoff'))}"]`,
    '  readModel["Harness read model<br/>/api/v1/dashboard/harness-health"]',
    '  labUi["Lab / harness<br/>live Mermaid + detail cards"]',
    '  taskDone -->|"verdict_recorded"| evaluator',
    '  keeperTurn -->|"pre_compact"| preCompact',
    '  keeperRollover -->|"keeper_handoff"| handoff',
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
          <div class="text-sm font-medium text-[var(--text-strong)]">Live State Graph</div>
          <div class="mt-1 text-sm leading-[1.6] text-[var(--text-muted)]">
            task completion, pre-compaction, handoff가 read model로 모이는 구조를 한 장으로 보여줍니다.
          </div>
        </div>
        <div class="text-xs text-[var(--text-dim)]">
          가장 최근 rail ${active ? railTitle(active) : '없음'}
        </div>
      </div>

      <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-dim)]">
        <span class="rounded-full border border-[var(--white-8)] px-2 py-1">실선: live signal</span>
        <span class="rounded-full border border-[var(--white-8)] px-2 py-1">점선: snapshot reconciliation</span>
        <span class="rounded-full border border-[var(--accent)] px-2 py-1 text-[var(--text-body)]">강조: 가장 최근 rail</span>
      </div>

      <${MermaidGraph}
        source=${source}
        prefix="harness-flow"
        fallbackText=${fallbackText}
        minHeightClass="min-h-[260px]"
        diagramClass="border border-[var(--white-8)]"
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
  useEffect(handleHarnessSSE, [lastEvent.value])

  const s = harness.state.value
  const data = s.status === 'loaded' ? s.data : undefined
  const cal = data?.calibration
  const rejectRate = cal && cal.total_verdicts > 0
    ? ((cal.reject_count / cal.total_verdicts) * 100).toFixed(1)
    : '0'
  const agreementPct = cal ? (cal.agreement_rate * 100).toFixed(1) : '-'
  const fallbackCount = cal?.fallback_count ?? 0
  const fallbackPct = data ? Math.round((data.overview.fallback_ratio ?? 0) * 100) : 0
  const fallbackReasons = cal?.recent_fallback_reasons ?? []
  const flowSource = data ? buildHarnessFlowMermaid(data) : null

  return html`
    <div class="space-y-4">
      <${Card} title="Safety Harness" class="section">
        ${s.status === 'loading' || s.status === 'idle' ? html`
          <div class="text-sm text-[var(--text-dim)]">로딩 중...</div>
        ` : s.status === 'error' ? html`
          <div class="text-sm text-[var(--bad)]">${s.message}</div>
        ` : !data ? html`
          <${EmptySignal} text="Harness 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] p-4">
              <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div class="max-w-3xl">
                  <div class="text-[10px] uppercase tracking-[0.18em] text-[var(--text-muted)]">Can I Trust The Experiment Machinery?</div>
                  <div class="mt-2 text-2xl font-semibold text-[var(--text-strong)]">${heroTitle(data)}</div>
                  <div class="mt-2 text-sm leading-[1.7] text-[var(--text-body)]">${heroBody(data)}</div>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    class="rounded border border-[var(--white-8)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] transition-colors hover:border-[var(--accent)] hover:text-[var(--text-body)]"
                    onClick=${() => { void loadHarnessHealth() }}
                  >새로고침</button>
                  <button
                    type="button"
                    class="rounded border border-[var(--white-8)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] transition-colors hover:border-[var(--ok-30)] hover:text-[var(--text-body)]"
                    onClick=${() => navigate('lab', { section: 'autoresearch' })}
                  >오토리서치 보기</button>
                </div>
              </div>

              <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-3">
                <${HeroRailCard}
                  label="Evaluator"
                  status=${data.overview.evaluator_status}
                  detail=${railDetail(data, 'evaluator')}
                  freshness=${railFreshness(data, 'evaluator')}
                />
                <${HeroRailCard}
                  label="Pre-Compaction"
                  status=${data.overview.pre_compact_status}
                  detail=${railDetail(data, 'pre_compact')}
                  freshness=${railFreshness(data, 'pre_compact')}
                />
                <${HeroRailCard}
                  label="Handoff"
                  status=${data.overview.handoff_status}
                  detail=${railDetail(data, 'handoff')}
                  freshness=${railFreshness(data, 'handoff')}
                />
              </div>

              <div class="mt-4 text-xs text-[var(--text-dim)]">
                generated ${formatTimestamp(data.generated_at)} · 마지막 안전 신호 ${freshnessLabel(data.overview.last_signal_at)}
              </div>
            </div>

            <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] px-4 py-3 text-sm leading-[1.7] text-[var(--text-body)]">
              ${data.scope_note}
            </div>

            <${ScopePairing} />
          </div>
        `}
      <//>

      <${Card} title="Harness Flow" class="section">
        ${!data || !flowSource ? html`
          <${EmptySignal} text="Harness flow 데이터가 없습니다." />
        ` : html`
          <${HarnessFlowCard} data=${data} />
        `}
      <//>

      <${Card} title="Evaluator Calibration" class="section">
        ${!data || !cal ? html`
          <${EmptySignal} text="Evaluator calibration 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="Judge of the Judge"
              description="실험 cycle 자체가 아니라, verdict 기계가 얼마나 건강하게 작동하는지 봅니다."
              status=${data.overview.evaluator_status}
              lastEventAt=${data.overview.evaluator_last_event_at}
            />

            ${fallbackPct > 80 ? html`
              <div class="rounded-lg border border-[var(--warn-30)] bg-[var(--warn-12)] px-4 py-3">
                <div class="mb-1 text-sm font-medium text-[var(--warn)]">Evaluator 미연결</div>
                <div class="text-xs text-[var(--warn)]">
                  전체 ${cal.total_verdicts}건 중 ${fallbackCount}건이 fallback으로 처리됐습니다.
                  지금은 LLM evaluator보다 fallback gate가 더 많이 작동합니다.
                </div>
                ${fallbackReasons.length > 0 ? html`
                  <details class="mt-2">
                    <summary class="cursor-pointer text-xs text-[var(--warn)] opacity-70">최근 에러 (${fallbackReasons.length}건)</summary>
                    <div class="mt-1 space-y-1">
                      ${fallbackReasons.map(reason => html`
                        <div class="break-all font-mono text-xs text-[var(--warn)] opacity-70">${reason}</div>
                      `)}
                    </div>
                  </details>
                ` : null}
              </div>
            ` : null}

            <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <${StatCard} label="총 Verdict" value=${cal.total_verdicts} />
              <${StatCard} label="Reject 비율" value="${rejectRate}%" />
              <${StatCard} label="Fallback 비율" value="${fallbackPct}%" />
              <${StatCard}
                label="일치율"
                value="${agreementPct}%"
                sub="FP:${cal.false_positive_count} FN:${cal.false_negative_count}"
              />
            </div>

            <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] p-3 text-xs leading-[1.6] text-[var(--text-muted)]">
              인간 라벨 ${cal.labeled_count}건이 calibration ground truth입니다. 값이 0이면 runtime health는 볼 수 있어도 evaluator accuracy는 아직 검증되지 않았습니다.
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--text-dim)]">Gate 분포</div>
              <${GateChart} distribution=${cal.gate_distribution} />
            </div>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wider text-[var(--text-dim)]">최근 Verdict</div>
              <${RecentVerdictsList} items=${data.recent_verdicts} />
            </div>
          </div>
        `}
      <//>

      <${Card} title="Pre-Compaction Rail" class="section">
        ${!data ? html`
          <${EmptySignal} text="Pre-compaction 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="Continuity Pressure"
              description=${data.pre_compact.description}
              status=${data.pre_compact.status}
              lastEventAt=${data.pre_compact.last_event_at}
            />
            <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
              <${StatCard}
                label="최근 ratio"
                value=${data.overview.latest_pre_compact_ratio != null ? data.overview.latest_pre_compact_ratio.toFixed(2) : '-'}
                sub=${`최근 ${data.pre_compact.total_recent}건`}
              />
              <${StatCard}
                label="최근 freshness"
                value=${freshnessLabel(data.pre_compact.last_event_at)}
              />
              <${StatCard}
                label="status"
                value=${railStatusLabel(data.pre_compact.status)}
              />
            </div>
            <${PreCompactList} section=${data.pre_compact} />
          </div>
        `}
      <//>

      <${Card} title="Handoff Rail" class="section">
        ${!data ? html`
          <${EmptySignal} text="Handoff 데이터가 없습니다." />
        ` : html`
          <div class="space-y-4">
            <${RailHeader}
              title="Keeper Handoff"
              description=${data.recent_handoffs.description}
              status=${data.recent_handoffs.status}
              lastEventAt=${data.recent_handoffs.last_event_at}
            />
            <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
              <${StatCard}
                label="최근 generation"
                value=${data.overview.latest_handoff_generation != null ? data.overview.latest_handoff_generation : '-'}
                sub=${`최근 ${data.recent_handoffs.total_recent}건`}
              />
              <${StatCard}
                label="최근 freshness"
                value=${freshnessLabel(data.recent_handoffs.last_event_at)}
              />
              <${StatCard}
                label="status"
                value=${railStatusLabel(data.recent_handoffs.status)}
              />
            </div>
            <${HandoffList} section=${data.recent_handoffs} />
          </div>
        `}
      <//>
    </div>
  `
}
