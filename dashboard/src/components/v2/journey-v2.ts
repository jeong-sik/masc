// MASC v2 — 턴 워터폴 (ported from prototype journey.jsx JourneyPanel).
// Emits the prototype `.jw-*` / `.ev-*` / `.lq-*` DOM so the vendored
// keeper-v2 skin (styles/keeper-v2/lanes.css) applies unchanged.
//
// Live wiring (mark, don't fake):
//   · waterfall turns/entries — buildJourneyWaterfall over the same three
//     keeper APIs (trajectory, tool-call I/O, runtime trace), re-fetched
//     per selected keeper tab.
//   · lq-tabs — `keepers` execution-projection signal; `lq-tab-none` marks
//     keepers with no recorded turn count in the projection.
//   · lq-kpis — derived from the loaded waterfall model summary.
//   · ev-* live strip — global `journal` SSE ring buffer (same source as
//     agent-monitor/live-timeline.ts), filter chips + events/min.
//
// Not ported: the design's per-turn stimuli strip. No backend signal records
// which payloads a past turn processed — run_state.stimulus_kinds is a
// current-snapshot field only, so the sub-component is omitted rather than
// faked.

import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'

import {
  fetchKeeperToolCalls,
  fetchKeeperTrajectory,
  type ToolCallsResponse,
  type TrajectoryResponse,
} from '../../api/dashboard'
import {
  fetchKeeperRuntimeTrace,
  type KeeperRuntimeTraceResponse,
} from '../../api/keeper'
import { journal } from '../../sse'
import { isErrorJournalEntry } from '../../journal-entry'
import { errorToString } from '../../lib/format-string'
import { useManagedAsyncResource } from '../../lib/use-managed-async-resource'
import { keepers } from '../../store'
import type { JournalEntry, Keeper } from '../../types'
import { TimeAgo } from '../common/time-ago'
import {
  buildJourneyWaterfall,
  selectDefaultJourneyKeeper,
  type JourneyWaterfallEntry,
  type JourneyWaterfallModel,
  type JourneyWaterfallRuntimeEvidence,
  type JourneyWaterfallTurn,
} from '../journey-waterfall-state'

// --- prototype lookup tables (journey.jsx) ---

const ENTRY_STATUS: Readonly<Record<string, { lbl: string; tone: string }>> = {
  success: { lbl: '성공', tone: 'ok' },
  failure: { lbl: '실패', tone: 'bad' },
  gate_rejected: { lbl: '승인 대기로 전환', tone: 'warn' },
  unknown: { lbl: '미판정', tone: 'dim' },
}

const ENTRY_STATUS_UNKNOWN = { lbl: '미판정', tone: 'dim' } as const

function entryStatus(status: string): { lbl: string; tone: string } {
  return ENTRY_STATUS[status] ?? ENTRY_STATUS_UNKNOWN
}

const ENTRY_SOURCE: Readonly<Record<string, string>> = {
  trajectory: 'trajectory',
  'trajectory+tool_call_log': 'trajectory+log',
  tool_call_log: 'tool_call_log',
  unknown: '출처 미기록',
}

const EV_CHIPS: ReadonlyArray<readonly [EvFilter, string]> = [
  ['all', '전체'],
  ['heartbeat', '하트비트'],
  ['message', '메시지/보드'],
  ['agent_core_turn', '턴'],
  ['tool', '도구'],
  ['error', '오류'],
  ['lifecycle', '상태 변화'],
]

type EvFilter = 'all' | 'heartbeat' | 'message' | 'agent_core_turn' | 'tool' | 'error' | 'lifecycle'

/** badge code → [raw badge, tone, filter group] (journey.jsx EV_BADGE). */
const EV_BADGE: Readonly<Record<string, readonly [string, string, string]>> = {
  keeper_heartbeat: ['HB', 'ok', 'heartbeat'],
  agent_core_turn: ['TURN', 'info', 'agent_core_turn'],
  agent_core_tool: ['TOOL', 'warn', 'tool'],
  keeper_tool_call: ['TOOL', 'warn', 'tool'],
  agent_core_event: ['Agent Core', 'info', 'lifecycle'],
  keeper_handoff: ['HAND', 'info', 'lifecycle'],
  keeper_phase_changed: ['PHASE', 'info', 'lifecycle'],
  broadcast: ['CAST', 'info', 'message'],
  board_post: ['POST', 'info', 'message'],
  board_comment: ['CMNT', 'info', 'message'],
  unknown: ['SYS', 'dim', 'other'],
}

const EV_KO: Readonly<Record<string, string>> = {
  HB: '하트비트',
  TURN: '턴',
  TOOL: '도구',
  'Agent Core': '내부',
  HAND: '인계',
  PHASE: '단계',
  CAST: '알림',
  POST: '게시',
  CMNT: '댓글',
  SYS: '시스템',
}

function msTxt(ms: number | null): string {
  if (ms == null) return '미기록'
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`
  return `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s`
}

function isHealthy(health: string): boolean {
  const normalized = health.trim().toLowerCase()
  return normalized === 'healthy' || normalized === 'ok'
}

// --- waterfall loading (trajectory + tool-call I/O + runtime trace) ---

interface WaterfallLoadResult {
  model: JourneyWaterfallModel
  sourceErrors: string[]
}

type SettledSource<T> =
  | { ok: true; data: T }
  | { ok: false; label: string; error: string }

async function settleSource<T>(
  label: string,
  promise: Promise<T>,
): Promise<SettledSource<T>> {
  try {
    return { ok: true, data: await promise }
  } catch (err) {
    return { ok: false, label, error: errorToString(err) }
  }
}

async function fetchWaterfallSources(
  keeperName: string,
  signal: AbortSignal,
): Promise<WaterfallLoadResult> {
  const [trajectory, toolCalls, runtimeTrace] = await Promise.all([
    settleSource<TrajectoryResponse>(
      'trajectory',
      fetchKeeperTrajectory(keeperName, 200, true, true),
    ),
    settleSource<ToolCallsResponse>(
      'tool-calls',
      fetchKeeperToolCalls(keeperName, 200, { signal }),
    ),
    settleSource<KeeperRuntimeTraceResponse>(
      'runtime-trace',
      fetchKeeperRuntimeTrace(keeperName, { limit: 200, signal }),
    ),
  ])

  const sourceErrors = [trajectory, toolCalls, runtimeTrace]
    .filter((result): result is Extract<SettledSource<unknown>, { ok: false }> => !result.ok)
    .map(result => `${result.label}: ${result.error}`)

  if (!trajectory.ok && !toolCalls.ok && !runtimeTrace.ok) {
    throw new Error(sourceErrors.join(' | ') || 'waterfall sources unavailable')
  }

  return {
    model: buildJourneyWaterfall({
      keeper: keeperName,
      trajectory: trajectory.ok ? trajectory.data : null,
      toolCalls: toolCalls.ok ? toolCalls.data : null,
      runtimeTrace: runtimeTrace.ok ? runtimeTrace.data : null,
    }),
    sourceErrors,
  }
}

// --- evidence strip (journey.jsx EvidenceStrip) ---

function EvidenceStrip({
  ev,
  dev,
}: {
  ev: JourneyWaterfallRuntimeEvidence | null
  dev: boolean
}) {
  if (!ev) return html`<div class="jw-ev none">실행 기록 없음</div>`

  const dispatched = ev.runtimeCompletedCount + ev.runtimeFailedCount
  const items: Array<readonly [string, string | number, string]> = dev
    ? [
        ['health', ev.health, isHealthy(ev.health) ? 'ok' : 'warn'],
        ['trace_id', ev.traceId, 'dim'],
        [
          'keeper_turn_id',
          ev.keeperTurnId == null
            ? '미기록'
            : `${ev.keeperTurnId} / max ${ev.maxAgentCoreTurnCount ?? '미기록'}`,
          'dim',
        ],
        [
          'runtime dispatch',
          dispatched === 0
            ? '관측 없음'
            : `완료 ${ev.runtimeCompletedCount} · 실패 ${ev.runtimeFailedCount}`,
          dispatched === 0 ? 'dim' : ev.runtimeCompletedCount > 0 ? 'ok' : 'bad',
        ],
        ['event bus 상관', ev.eventBusCorrelatedCount, 'dim'],
        ['memory', `주입 ${ev.memoryInjectedCount} · flush ${ev.memoryFlushedCount}`, 'dim'],
      ]
    : [
        ['상태', isHealthy(ev.health) ? '정상' : '오래된 기록', isHealthy(ev.health) ? 'ok' : 'warn'],
        // 후보를 순서대로 부르다가 먼저 응답한 곳에서 멈추므로, 한 번
        // 실패하고 다음 후보에서 성공한 턴은 실패와 완료를 함께 남긴다.
        // 실패 수를 먼저 보면 그런 턴이 전부 실패로 보여서, 완료가 있으면
        // 성공으로 읽고 실패 횟수는 괄호로만 적는다.
        [
          '모델 호출',
          dispatched === 0
            ? '관측 없음'
            : ev.runtimeCompletedCount > 0
              ? ev.runtimeFailedCount > 0
                ? `성공 (재시도 ${ev.runtimeFailedCount}건)`
                : '성공'
              : `실패 ${ev.runtimeFailedCount}건`,
          dispatched === 0 ? 'dim' : ev.runtimeCompletedCount > 0 ? 'ok' : 'bad',
        ],
        ['기억', `불러옴 ${ev.memoryInjectedCount} · 저장 ${ev.memoryFlushedCount}`, 'dim'],
      ]

  return html`
    <div class="jw-ev">
      ${items.map(([key, value, tone]) => html`
        <span key=${key} class="jw-ev-i" data-tone=${tone}><i>${key}</i><b class="mono">${value}</b></span>
      `)}
      ${ev.staleReason
        ? html`<span class="jw-ev-stale">${dev ? `stale · ${ev.staleReason}` : '오래된 기록입니다'}</span>`
        : null}
    </div>
  `
}

// --- turn card (journey.jsx TurnCard) ---

interface TimedEntry {
  entry: JourneyWaterfallEntry
  /** ms since the turn's first entry (design `at`). */
  at: number
  /** entry.durationMs, null-able (design `dur`). */
  dur: number | null
}

function timedEntries(turn: JourneyWaterfallTurn): TimedEntry[] {
  return turn.entries.map(entry => ({
    entry,
    at: Math.max(0, entry.ts - turn.startTs),
    dur: entry.durationMs,
  }))
}

function turnSpan(timed: TimedEntry[]): number {
  return Math.max(1, ...timed.map(t => t.at + (t.dur || 0)))
}

/** Greedy lane packing so concurrent batches stack on separate rows
 * (journey.jsx TurnCard lanes). */
function packLanes(tools: TimedEntry[]): TimedEntry[][] {
  const lanes: TimedEntry[][] = []
  for (const tool of tools) {
    const index = lanes.findIndex(row =>
      row.every(x => tool.at >= x.at + (x.dur || 0) + 200),
    )
    if (index < 0) lanes.push([tool])
    else lanes[index]?.push(tool)
  }
  return lanes
}

function TurnCard({
  turn,
  open,
  onToggle,
  dev,
}: {
  turn: JourneyWaterfallTurn
  open: boolean
  onToggle: () => void
  dev: boolean
}) {
  const [pick, setPick] = useState<string | null>(null)
  const timed = timedEntries(turn)
  const span = turnSpan(timed)
  const tools = timed.filter(t => t.entry.kind === 'tool_call')
  const thinking = timed.filter(t => t.entry.kind === 'thinking')
  const lanes = packLanes(tools)
  const sel = pick ? turn.entries.find(entry => entry.id === pick) ?? null : null
  const totalDur = timed.reduce((sum, t) => sum + (t.dur || 0), 0)

  return html`
    <div class=${`jw-turn ${open ? 'open' : ''}`}>
      <button class="jw-turn-h" onClick=${onToggle}>
        <span class="jw-turn-t mono">${turn.turn == null ? '턴 번호 없음' : `${turn.turn}번째 턴`}</span>
        <span class="jw-turn-s">생각 ${thinking.length} · 도구 ${tools.length}</span>
        ${turn.failureCount > 0
          ? html`<span class="lq-chip" data-tone="bad">실패 ${turn.failureCount}</span>`
          : null}
        ${turn.gateRejectedCount > 0
          ? html`<span class="lq-chip" data-tone="warn">승인 대기 ${turn.gateRejectedCount}</span>`
          : null}
        <span class="jw-turn-d mono">${msTxt(totalDur)}</span>
        <span class="jw-caret" aria-hidden="true">${open ? '▾' : '▸'}</span>
      </button>
      ${open
        ? html`
            <div class="jw-body">
              <div class="jw-track">
                <div class="jw-think">
                  ${thinking.map(t => html`
                    <button
                      key=${t.entry.id}
                      class=${`jw-think-m ${pick === t.entry.id ? 'on' : ''}`}
                      style=${{ left: `${(t.at / span) * 100}%` }}
                      onClick=${() => setPick(pick === t.entry.id ? null : t.entry.id)}
                      title=${t.entry.summary}
                    >◇</button>
                  `)}
                </div>
                ${lanes.map((row, ri) => html`
                  <div key=${ri} class="jw-lane">
                    ${row.map(t => {
                      const st = entryStatus(t.entry.status)
                      const width = Math.max(3, ((t.dur || 300) / span) * 100)
                      const label = t.entry.toolName ?? t.entry.summary
                      return html`
                        <button
                          key=${t.entry.id}
                          class=${`jw-bar ${pick === t.entry.id ? 'on' : ''}`}
                          data-tone=${st.tone}
                          style=${{ left: `${(t.at / span) * 100}%`, width: `${width}%` }}
                          onClick=${() => setPick(pick === t.entry.id ? null : t.entry.id)}
                          title=${`${label} · ${msTxt(t.dur)} · ${st.lbl}`}
                        >
                          ${((t.dur || 300) / span) >= 0.13
                            ? html`<span class="jw-bar-l mono">${label}</span>`
                            : null}
                        </button>
                      `
                    })}
                  </div>
                `)}
                <div class="jw-scale"><span class="mono">0</span><span class="mono">${msTxt(span)}</span></div>
              </div>
              ${sel
                ? (() => {
                    const st = entryStatus(sel.status)
                    return html`
                      <div class="jw-detail" data-tone=${st.tone}>
                        <div class="jw-detail-h">
                          <b class="mono">${sel.kind === 'thinking' ? 'thinking' : sel.toolName ?? sel.summary}</b>
                          <span class="lq-chip" data-tone=${st.tone}>${st.lbl}</span>
                          ${dev
                            ? html`<span class="jw-src mono">${ENTRY_SOURCE[sel.source] ?? sel.source}</span>`
                            : null}
                          ${sel.durationMs != null
                            ? html`<span class="mono">${msTxt(sel.durationMs)}</span>`
                            : null}
                          ${sel.executionMode
                            ? html`<span class="jw-mode mono">${dev
                                ? `${sel.executionMode} · batch ${sel.batchIndex ?? '?'}/${sel.batchSize ?? '?'}${sel.plannedIndex != null ? ` · planned #${sel.plannedIndex}` : ''}`
                                : sel.executionMode === 'concurrent'
                                  ? '동시 실행'
                                  : '순차 실행'}</span>`
                            : null}
                        </div>
                        <div class="jw-detail-b">
                          ${sel.thinkingRedacted
                            ? '사고 내용은 비공개 처리되어 요약만 남습니다.'
                            : sel.summary}
                        </div>
                        ${sel.gateReason
                          ? html`<div class="jw-detail-r warn">${sel.gateReason}</div>`
                          : null}
                        ${sel.error
                          ? html`<div class="jw-detail-r bad">${dev ? `error · ${sel.error}` : `실패 · ${sel.error}`}</div>`
                          : null}
                      </div>
                    `
                  })()
                : null}
              <${EvidenceStrip} ev=${turn.runtimeEvidence} dev=${dev} />
            </div>
          `
        : null}
    </div>
  `
}

// --- live event strip (journey.jsx LiveStrip) ---

const EV_BADGE_UNKNOWN: readonly [string, string, string] = ['SYS', 'dim', 'other']

function entryBadge(entry: JournalEntry): readonly [string, string, string] {
  return EV_BADGE[entry.eventType ?? 'unknown'] ?? EV_BADGE_UNKNOWN
}

function entryMatchesFilter(entry: JournalEntry, filter: EvFilter): boolean {
  if (filter === 'all') return true
  if (filter === 'error') return isErrorJournalEntry(entry)
  return entryBadge(entry)[2] === filter
}

function compactEventText(value: string, max = 120): string {
  const text = value.replace(/\s+/g, ' ').trim()
  return text.length > max ? `${text.slice(0, max - 1)}...` : text
}

function LiveStrip({ dev }: { dev: boolean }) {
  const [filter, setFilter] = useState<EvFilter>('all')
  // journal ring buffer, newest first — the design's "최근 50건" window.
  const entries = journal.value.slice(0, 50)
  const rows = entries.filter(entry => entryMatchesFilter(entry, filter))
  // events/min reads Date.now() on each render so the 60s window keeps
  // sliding even when the journal is quiet (same rule as live-timeline.ts).
  const cutoff = Date.now() - 60_000
  const perMin = entries.filter(entry => entry.timestamp > cutoff).length

  return html`
    <div class="ev">
      <div class="ev-head">
        <div class="ev-chips">
          ${EV_CHIPS.map(([key, label]) => html`
            <button
              key=${key}
              class=${`ia-filter ${filter === key ? 'on' : ''}`}
              onClick=${() => setFilter(key)}
            >${label}</button>
          `)}
        </div>
        <span class="ev-rate mono">${perMin}/min</span>
        <span class="ev-count mono">${rows.length} events</span>
      </div>
      ${rows.length === 0
        ? html`<div class="lq-gap"><b>해당 이벤트 없음</b></div>`
        : html`
            <div class="ev-rows">
              ${rows.map((entry, index) => {
                const badge = entryBadge(entry)
                const err = isErrorJournalEntry(entry)
                return html`
                  <div key=${index} class="ev-row">
                    <span class=${`lq-chip ${dev ? 'mono' : ''}`} data-tone=${err ? 'bad' : badge[1]}>
                      ${dev ? badge[0] : EV_KO[badge[0]] ?? badge[0]}
                    </span>
                    <span class="ev-text">${compactEventText(entry.text)}</span>
                    <span class="ev-ago mono"><${TimeAgo} timestamp=${entry.timestamp} /></span>
                  </div>
                `
              })}
            </div>
          `}
    </div>
  `
}

// --- panel (journey.jsx JourneyPanel) ---

function keeperHasTurnRecords(keeper: Keeper): boolean {
  const turns = keeper.turn_count ?? keeper.total_turns ?? null
  if (typeof turns === 'number' && turns > 0) return true
  return keeper.last_turn_ago_s != null
}

export function JourneyV2Panel() {
  const keeperRows = keepers.value
  const [selectedKeeper, setSelectedKeeper] = useState<string | null>(() =>
    selectDefaultJourneyKeeper(keeperRows),
  )
  const [openKey, setOpenKey] = useState<string | null>(null)
  const [dev, setDev] = useState(false)
  const resource = useManagedAsyncResource<WaterfallLoadResult>(null)

  useEffect(() => {
    const next = selectDefaultJourneyKeeper(keeperRows, selectedKeeper)
    if (next !== selectedKeeper) setSelectedKeeper(next)
  }, [keeperRows, selectedKeeper])

  const refresh = useCallback(() => {
    if (!selectedKeeper) {
      resource.reset(null)
      return
    }
    void resource.load(signal => fetchWaterfallSources(selectedKeeper, signal))
  }, [resource, selectedKeeper])

  useEffect(() => {
    setOpenKey(null)
    refresh()
    return () => {
      resource.cancel()
    }
  }, [refresh, resource])

  const state = resource.state.value
  const model = state.data?.model ?? null
  const summary = model?.summary ?? null
  // openKey null = "not chosen yet" → default to the first card, like the
  // design's initial `open='t0'`. Toggling that card shut stores NONE so the
  // default does not re-open it.
  const NONE_OPEN = '__none__'
  const open = openKey === NONE_OPEN ? null : openKey ?? model?.turns[0]?.key ?? null

  return html`
    <div class="ia-wrap jw-wrap">
      <div class="ia-head">
        <h3>턴 워터폴</h3>
        <span class="ia-count">턴 안에서 무엇을 얼마나 오래 했는가</span>
        <span class="ia-devslot">
          <button class=${`ia-filter ${dev ? 'on' : ''}`} onClick=${() => setDev(!dev)}>기술 상세</button>
        </span>
      </div>
      <p class="ia-lede">
        막대를 누르면 무엇을 했고 왜 실패했는지 나옵니다. 턴의 최종 텍스트는 자동 전달되지 않습니다 — 발화 도구로 보낸 것만 나갑니다.
      </p>

      <div class="lq-kpis">
        <div class="lq-kpi"><span class="k">턴</span><b>${summary?.totalTurns ?? 0}</b></div>
        <div class="lq-kpi">
          <span class="k">생각 · 도구</span>
          <b>${summary ? `${summary.thinkingCount} · ${summary.toolCallCount}` : '0 · 0'}</b>
        </div>
        <div class="lq-kpi">
          <span class="k">실패</span>
          <b class=${summary && summary.failureCount > 0 ? 'bad' : 'ok'}>${summary?.failureCount ?? 0}</b>
        </div>
        <div class="lq-kpi">
          <span class="k">승인 대기로 전환</span>
          <b class=${summary && summary.gateRejectedCount > 0 ? 'warn' : 'ok'}>${summary?.gateRejectedCount ?? 0}</b>
        </div>
        <div class="lq-kpi">
          <span class="k">도구 사용 시간</span>
          <b class="mono">${msTxt(summary?.totalDurationMs ?? null)}</b>
        </div>
      </div>

      <div class="lq-sec">
        <div class="lq-sec-h">
          <h4>워터폴</h4>
          <div class="lq-tabs">
            ${keeperRows.map(keeper => html`
              <button
                key=${keeper.name}
                class=${`lq-tab mono ${selectedKeeper === keeper.name ? 'on' : ''}`}
                onClick=${() => setSelectedKeeper(keeper.name)}
              >
                ${keeper.name}
                ${!keeperHasTurnRecords(keeper)
                  ? html`<i class="lq-tab-none">·</i>`
                  : null}
              </button>
            `)}
          </div>
        </div>
        ${state.loading && !model
          ? html`<div class="lq-gap"><b>턴 기록을 불러오는 중…</b></div>`
          : state.error
            ? html`<div class="lq-gap"><b>턴 기록을 불러오지 못했습니다</b><span class="mono">${state.error}</span></div>`
            : !model || model.turns.length === 0
              ? html`<div class="lq-gap"><b>최근 턴 기록 없음</b></div>`
              : model.turns.map(turn => html`
                  <${TurnCard}
                    key=${turn.key}
                    turn=${turn}
                    dev=${dev}
                    open=${open === turn.key}
                    onToggle=${() => setOpenKey(open === turn.key ? NONE_OPEN : turn.key)}
                  />
                `)}
      </div>

      <div class="lq-sec">
        <div class="lq-sec-h">
          <h4>라이브 이벤트</h4>
          ${dev ? html`<span class="mono">journal ring buffer · 최근 50건</span>` : null}
        </div>
        <${LiveStrip} dev=${dev} />
      </div>
    </div>
  `
}
