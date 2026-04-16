// Activity graph surface — runtime event graph + timeline

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { createAsyncResource } from '../lib/async-state'
import { Card } from './common/card'
import { EmptyState, LoadingState } from './common/feedback-state'
import { ActionButton } from './common/button'
import { FilterChips } from './common/filter-chips'
import { TimeAgo } from './common/time-ago'
import { Sparkline } from './common/sparkline'
import { GraphView } from './activity-graph-view'
import { ActivitySwimlane } from './activity-swimlane'
import { ActivityHeatmap } from './activity-heatmap'
import { KeeperPhaseTimeline } from './keeper-phase-strip'
import { CollapsibleSection } from './common/collapsible'
import {
  buildActionTimelineGroups,
  buildCategoryCounts,
  buildRawCategoryCounts,
  categoryLabel,
  eventDetail,
  eventKindLabel as activityEventKindLabel,
  type ActionTimelineFilter,
} from './activity-graph-groups'
import { fetchActivityGraph } from '../api'
import { registerActivityRefresh } from '../sse-store'
import { hashForRoute } from '../router'
import {
  currentTimeRangeFilter,
  timeRangeLabel,
  type TimeRangePreset,
} from '../observatory-filter-store'
import type { ActivityGraphResponse, ActivityGraphNode, ActionTimelineGroup } from '../types'

const graphResource = createAsyncResource<ActivityGraphResponse | null>()
const DEFAULT_ACTIVITY_RANGE: TimeRangePreset = '1h'

const actionFilter = signal<ActionTimelineFilter>('all')
const showLifecycle = signal(false)
const expandedActionGroups = signal<Set<string>>(new Set())

export function visibleNamespaceLabel(namespaceId: string | null | undefined): string | null {
  const value = typeof namespaceId === 'string' ? namespaceId.trim() : ''
  if (!value || value === 'default') return null
  return value
}

function activityRange(): TimeRangePreset {
  return currentTimeRangeFilter() ?? DEFAULT_ACTIVITY_RANGE
}

function loadGraph() {
  return graphResource.load(() => {
    return fetchActivityGraph(activityRange())
  })
}

function StatsRow({ data }: { data: ActivityGraphResponse }) {
  const s = data.stats
  const h = data.stats_history ?? []
  const evSeries = h.map(b => b.events)
  const agSeries = h.map(b => b.active_agents)
  const tdSeries = h.map(b => b.tasks_done)

  function statCard(label: string, value: number, series: number[], color: string, highlight = false) {
    return html`
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">${label}</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums ${highlight ? 'text-[var(--ok)]' : ''}">${value}</div>
        ${series.length >= 2 ? html`<div class="mt-2"><${Sparkline} values=${series} color=${color} /></div>` : null}
      </div>
    `
  }

  return html`
    <div class="stats-grid grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3 mb-4">
      ${statCard('노드', s.node_count ?? 0, [], '#94a3b8')}
      ${statCard('엣지', s.edge_count ?? 0, [], '#64748b')}
      ${statCard('활성 에이전트', s.active_agents ?? 0, agSeries, '#4ade80', true)}
      ${statCard('작업', s.task_count ?? 0, tdSeries, '#fbbf24')}
      ${statCard('이벤트', s.event_count ?? 0, evSeries, '#a78bfa')}
    </div>
  `
}

function actionCategoryClass(group: ActionTimelineGroup): string {
  switch (group.category) {
    case 'task':
      return 'border-[#fbbf24]/35 bg-[#fbbf24]/10 text-[var(--warn)]'
    case 'session':
      return 'border-[#4ade80]/35 bg-[var(--ok)]/10 text-[var(--ok-20)]'
    case 'message':
      return 'border-[#22d3ee]/35 bg-[#22d3ee]/10 text-[var(--cyan)]'
    case 'board':
      return 'border-[#c084fc]/35 bg-[#c084fc]/10 text-[var(--purple)]'
    case 'governance':
      return 'border-[#fb7185]/35 bg-[var(--bad)]/10 text-[var(--bad-light)]'
    case 'lifecycle':
      return 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)]'
    default:
      return 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-muted)]'
  }
}

function toggleExpandedGroup(id: string): void {
  const next = new Set(expandedActionGroups.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedActionGroups.value = next
}

function ActionTimeline({ data }: { data: ActivityGraphResponse }) {
  const groups = buildActionTimelineGroups(data.timeline)
  const visibleBaseGroups = showLifecycle.value
    ? groups
    : groups.filter(group => group.category !== 'lifecycle')
  const baseCounts = buildCategoryCounts(visibleBaseGroups)
  const rawCounts = buildRawCategoryCounts(data.kind_counts)
  const lifecycleHiddenCount = showLifecycle.value ? 0 : rawCounts.lifecycle
  const filter = actionFilter.value
  const filteredGroups = visibleBaseGroups.filter(group =>
    filter === 'all' ? true : group.category === filter,
  )
  const chips = [
    { key: 'all', label: 'All', count: visibleBaseGroups.length },
    { key: 'task', label: 'Task', count: baseCounts.task },
    { key: 'session', label: 'Session', count: baseCounts.session },
    { key: 'message', label: 'Message', count: baseCounts.message },
    { key: 'board', label: 'Board', count: baseCounts.board },
    { key: 'governance', label: 'Governance', count: baseCounts.governance },
    ...(baseCounts.other > 0 || filter === 'other'
      ? [{ key: 'other' as const, label: 'Other', count: baseCounts.other }]
      : []),
  ]

  if (groups.length === 0) {
    return html`<${EmptyState} message="액션 단위로 묶을 실행 이벤트가 없습니다." compact />`
  }

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex flex-col gap-3 rounded-xl border border-[var(--card-border)] bg-[var(--card)]/50 p-4">
        <div class="flex flex-col gap-1">
          <div class="text-[14px] font-semibold text-[var(--text-strong)]">라이브 패널은 원본 스트림, 여기서는 최근 실행을 액션 단위로 묶어 봅니다.</div>
          <div class="text-[12px] text-[var(--text-muted)]">
            액션 ${filteredGroups.length}개 · 원본 타임라인 ${data.timeline.length}건 · 분석 범위 ${data.stats.event_count ?? data.timeline.length}건
            ${lifecycleHiddenCount > 0 ? ` · lifecycle ${lifecycleHiddenCount}건 숨김` : ''}
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <${FilterChips} chips=${chips} active=${actionFilter} tone="accent" />
          <button
            type="button"
            class="inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1.5 text-[11px] transition-all duration-150 ${showLifecycle.value
              ? 'border-[var(--border-slate-22)] bg-[var(--accent-soft)] text-[var(--text-strong)]'
              : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)]'}"
            onClick=${() => { showLifecycle.value = !showLifecycle.value }}
          >
            Lifecycle ${showLifecycle.value ? '표시 중' : '숨김'}
            <span class="rounded-md bg-[var(--white-6)] px-1.5 py-0.5 text-[10px]">${rawCounts.lifecycle}</span>
          </button>
        </div>
      </div>

      ${filteredGroups.length === 0
        ? html`<${EmptyState} message="선택한 필터에 맞는 액션 그룹이 없습니다." compact />`
        : filteredGroups.map(group => {
            const expanded = expandedActionGroups.value.has(group.id)
            return html`
              <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)]/55 p-4 shadow-sm shadow-black/8" key=${group.id}>
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.08em] ${actionCategoryClass(group)}">
                        ${categoryLabel(group.category)}
                      </span>
                      ${group.actor ? html`<span class="text-[11px] font-medium text-[var(--text-body)]">${group.actor}</span>` : null}
                      ${group.subjectId ? html`<span class="text-[11px] text-[var(--text-muted)] font-mono">${group.subjectId}</span>` : null}
                    </div>
                    <div class="mt-2 text-[15px] font-semibold text-[var(--text-strong)]">${group.title}</div>
                    <div class="mt-1 text-[13px] leading-[1.6] text-[var(--text-body)]">${group.summary}</div>
                  </div>
                  <div class="flex shrink-0 flex-col items-end gap-2 text-[11px] text-[var(--text-muted)]">
                    <span>${group.rawCount} events</span>
                    <${TimeAgo} timestamp=${group.latestTs} />
                  </div>
                </div>
                <div class="mt-3 flex flex-wrap gap-1.5">
                  ${group.kinds.slice(0, 4).map(kind => html`
                    <span class="inline-flex items-center rounded-md border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]" key=${kind}>
                      ${activityEventKindLabel(kind)}
                    </span>
                  `)}
                </div>
                <div class="mt-3 flex items-center justify-between gap-3 border-t border-[var(--white-6)] pt-3">
                  <span class="text-[11px] text-[var(--text-muted)]">원본 이벤트를 펼쳐서 순서를 확인할 수 있습니다.</span>
                  <div class="flex items-center gap-2">
                    ${group.actor ? html`
                      <a
                        class="rounded-lg border border-[var(--accent-20)] bg-[var(--accent-soft)] px-3 py-1.5 text-[11px] text-[var(--accent)] no-underline transition-all duration-150 hover:bg-[var(--accent-10)]"
                        href=${hashForRoute('monitoring', { section: 'observatory', keeper: group.actor, range: activityRange() })}
                      >이 keeper로 보기</a>
                    ` : null}
                    <button
                      type="button"
                      class="rounded-lg border border-[var(--white-10)] bg-[var(--white-4)] px-3 py-1.5 text-[11px] text-[var(--text-body)] transition-all duration-150 hover:bg-[var(--white-8)]"
                      onClick=${() => toggleExpandedGroup(group.id)}
                    >
                      ${expanded ? '원본 접기' : '원본 보기'}
                    </button>
                  </div>
                </div>
                ${expanded ? html`
                  <div class="mt-3 flex flex-col gap-2 rounded-xl border border-[var(--white-8)] bg-[rgba(15,23,42,0.42)] p-3">
                    ${group.rawEvents.map(event => html`
                      <div class="flex items-start gap-3 rounded-lg border border-[var(--white-6)] bg-[var(--white-3)] px-3 py-2" key=${event.seq}>
                        <span class="inline-flex min-w-[72px] items-center rounded-md border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">
                          ${activityEventKindLabel(event.kind)}
                        </span>
                        <div class="min-w-0 flex-1">
                          <div class="text-[12px] text-[var(--text-body)]">${eventDetail(event, 160)}</div>
                           ${(() => { const ns = visibleNamespaceLabel(event.room_id); return ns
                             ? html`<div class="mt-1 text-[11px] text-[var(--text-muted)]">namespace: ${ns}</div>`
                             : null; })()}
                        </div>
                        <span class="shrink-0 text-[11px] text-[var(--text-muted)]">
                          <${TimeAgo} timestamp=${event.ts_iso} />
                        </span>
                      </div>
                    `)}
                  </div>
                ` : null}
              </div>
            `
          })}
    </div>
  `
}

function nodeScore(node: ActivityGraphNode): number {
  return node.semantic_weight ?? node.weight
}

function NodeLeaderboard({ nodes }: { nodes: ActivityGraphNode[] }) {
  const agentNodes = nodes
    .filter(n => n.kind === 'agent')
    .sort((a, b) => nodeScore(b) - nodeScore(a))
    .slice(0, 15)

  if (agentNodes.length === 0) {
    return html`<${EmptyState} message="활동 집계에 포함된 에이전트가 없습니다." compact />`
  }

  const maxScore = nodeScore(agentNodes[0]!) || 1

  return html`
    <div class="flex flex-col gap-1.5">
      ${agentNodes.map((node, i) => {
        const score = nodeScore(node)
        const pct = maxScore > 0 ? (score / maxScore) * 100 : 0
        return html`
          <div class="flex items-center gap-[10px] py-2 px-3 rounded-[10px] bg-[rgba(15,23,42,0.5)] border border-solid border-[var(--slate-gray-8)]" key=${node.id}>
            <span class="w-[22px] text-center text-sm font-bold text-text-slate">${i + 1}</span>
            <div class="flex-1 flex flex-col gap-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-base font-semibold text-[var(--text-near-white)] whitespace-nowrap overflow-hidden text-ellipsis">${node.label}</span>
                <span class="text-[11px] text-[var(--text-muted)]">${node.weight}회</span>
              </div>
              <div class="h-1 rounded-sm bg-[var(--slate-gray-10)] overflow-hidden">
                <div class="h-full rounded-sm bg-[var(--cyan)] transition-[width] duration-300 ease-in-out" style="width:${pct}%"></div>
              </div>
            </div>
            <span class="text-sm font-semibold text-text-slate-light min-w-[32px] text-right">${score.toFixed(1)}</span>
            <span class="text-[11px] py-0.5 px-[7px] rounded-md ${node.status === 'offline' || node.status === 'retired' ? 'text-[var(--text-slate)] bg-[var(--slate-gray-10)]' : 'text-[var(--ok)] bg-[var(--ok-10)]'}">${node.status}</span>
          </div>
        `
      })}
    </div>
  `
}

function EmptyActivityGraph() {
  return html`
    <div class="flex flex-col gap-5">
      <${Card} title="활동 분석" class="section mb-4" testId="activity_graph.graph">
        <div class="mb-4">
          <h2 class="monitor-headline">활동 분석 데이터가 비어 있습니다</h2>
          <p class="monitor-subheadline">이 뷰는 런타임 실행 이벤트를 읽어 타임라인과 파생 분석을 그립니다. 지금은 기록된 이벤트가 없어 화면이 비어 있습니다.</p>
        </div>
        <${EmptyState} message="아직 claim, broadcast, session runtime, board 같은 실행 이벤트가 activity feed에 기록되지 않았습니다." compact />
      <//>
    </div>
  `
}

export { loadGraph as refreshActivityGraph }

function useActivityGraphRefresh() {
  useEffect(() => {
    void loadGraph()
    return registerActivityRefresh(() => {
      void loadGraph()
    })
  }, [])
}

function useActivityGraphState() {
  useActivityGraphRefresh()
  return graphResource.state.value
}

function ActivityTimelinePanel({ data }: { data: ActivityGraphResponse }) {
  return html`
    <${Card} title="액션 타임라인" class="section" testId="activity_graph.timeline">
      <div class="max-h-[360px] overflow-y-auto">
        <${ActionTimeline} data=${data} />
      </div>
    <//>
  `
}

function DerivedActivityPanels({ data }: { data: ActivityGraphResponse }) {
  return html`
    <div class="flex flex-col gap-5">
      <${Card} title="실행 이벤트 관계 그래프" class="section mb-4" testId="activity_graph.graph">
        <div class="mb-4">
          <p class="monitor-subheadline">에이전트, 작업, 결정, 운영 이벤트 간의 연결을 시각화합니다. 관찰소의 시간 범위를 따라 파생 분석을 갱신합니다.</p>
        </div>
        <${StatsRow} data=${data} />
        <${GraphView} data=${data} />
        <div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[13px]">
          <span>생성 시각: ${data.generated_at}</span>
          <span>데이터 범위: 최근 ${data.window.limit}건 이벤트</span>
          <span>필터: ${timeRangeLabel(activityRange())}</span>
          ${(() => { const ns = visibleNamespaceLabel(data.window.room_id); return ns
            ? html`<span>namespace: ${ns}</span>`
            : null; })()}
        </div>
      <//>

      <${Card} title="활동 주체 순위" class="section" testId="activity_graph.leaderboard">
        <div class="mb-3">
          <p class="monitor-subheadline">의미적 중요도 기준. 작업 완료, 의사결정, 핸드오프가 단순 입퇴장보다 높게 평가됩니다.</p>
        </div>
        <${NodeLeaderboard} nodes=${data.nodes} />
      <//>

      ${data.timeline.length > 0 ? html`
        <${ActivityHeatmap} data=${data} />
      ` : null}
    </div>
  `
}

export function ObservatoryActivityPanels() {
  const state = useActivityGraphState()
  const data = state.status === 'loaded' ? state.data : undefined
  const since = activityRange()

  return html`
    <div class="flex flex-col gap-5">
      ${state.status === 'loading' || state.status === 'idle'
        ? html`<${LoadingState}>활동 분석 패널 불러오는 중...<//>`
        : state.status === 'error'
          ? html`
              <${Card} title="활동 분석" class="section" testId="activity_graph.error">
                <${EmptyState} message=${'활동 그래프를 불러올 수 없습니다: ' + state.message} compact />
                <${ActionButton} variant="ghost" onClick=${loadGraph}>다시 시도<//>
              <//>
            `
          : !data || (data.stats.event_count ?? 0) === 0
            ? html`<${EmptyActivityGraph} />`
            : html`<${ActivityTimelinePanel} data=${data} />`}

      <${CollapsibleSection} title="에이전트 타임라인">
        <${ActivitySwimlane} since=${since} />
      <//>

      <${CollapsibleSection} title="키퍼 상태 전환">
        <${KeeperPhaseTimeline} />
      <//>

      ${state.status === 'loaded' && data && (data.stats.event_count ?? 0) > 0 ? html`
        <${CollapsibleSection} title="파생 분석">
          <${DerivedActivityPanels} data=${data} />
        <//>
      ` : null}
    </div>
  `
}

export function ActivityGraphSurface() {
  const s = useActivityGraphState()

  const data = s.status === 'loaded' ? s.data : undefined

  if (s.status === 'loading' || s.status === 'idle') {
    return html`<${LoadingState}>활동 그래프 불러오는 중...<//>`
  }

  if (s.status === 'error') {
    return html`
      <div class="flex flex-col gap-5">
        <${Card} title="오류" class="section mb-4" testId="activity_graph.error">
          <${EmptyState} message=${'활동 그래프를 불러올 수 없습니다: ' + s.message} compact />
          <${ActionButton} variant="ghost" onClick=${loadGraph}>다시 시도<//>
        <//>
      </div>
    `
  }

  if (!data) {
    return html`<${EmptyState} message="활동 데이터가 없습니다." compact />`
  }

  if ((data.stats.event_count ?? 0) === 0) {
    return html`<${EmptyActivityGraph} />`
  }

  const since = activityRange()

  return html`
    <div class="flex flex-col gap-5">
      <${ActivityTimelinePanel} data=${data} />
      <${DerivedActivityPanels} data=${data} />

      <${CollapsibleSection} title="에이전트 타임라인">
        <${ActivitySwimlane} since=${since} />
      <//>

      <${CollapsibleSection} title="키퍼 상태 전환">
        <${KeeperPhaseTimeline} />
      <//>
    </div>
  `
}
