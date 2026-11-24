/**
 * `2 Work > Candle & Scorecard` Tab (`candle-tab.ts`)
 *
 * - Wired to `GET /api/v1/candle/ledger?limit=100` (`apiGetV2`, `V2Envelope`), safely parsing
 *   decimal-string `supply.*_milli` & `decayed_milli` vs numeric `balance_milli` (`#36`).
 * - `UPlotChart` Decayed Supply vs Cumulative Issuance trend.
 * - Native `<progress class="wk-gauge">` half-life decay gauge (zero inline styles!).
 * - Keeper Candle Leaderboard (`DataTable` with `<KeeperBadge portrait={true} />`).
 * - Unattributed / Backlog-Fenced / Held-Window diagnostics & Goal Candle Hold/Release action
 *   (`GET /api/v1/dashboard/goals/candle`, `POST /api/v1/dashboard/goals/candle/hold/release`).
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import { markViewSynced } from '../../core/observer'
import { observedAbsent, observedValue, resourceCache } from '../../core/resource-cache'
import { apiGet, apiGetV2, apiMutate } from '../../core/transport'
import { err, ok } from '../../lib/result'
import { KeeperBadge } from '../../components/keeper-badge'
import {
  DataTable,
  UPlotChart,
  type DataTableColumn,
  type UPlotSeriesSpec,
} from '../../components/primitives'
import {
  buildCandleTrendSeries,
  decodeCandleLedger,
  formatMilliCandles,
  formatRelativeTime,
  readWorkspacePrecondition,
  type CandleBalanceRow,
  type CandleLedgerData,
  type WorkspaceViewProps,
} from './types'

const CANDLE_SERIES: readonly UPlotSeriesSpec[] = [
  { label: '누적 발행 (Issued)', colorToken: '--info-fg', width: 1.75, unit: 'C' },
  { label: '감쇠 유통량 (Decayed)', colorToken: '--brass-1', width: 2, fillAlpha: 0.16, unit: 'C' },
]

export function CandleTab(props: WorkspaceViewProps) {
  const [ledger, setLedger] = useState<CandleLedgerData | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)

  const [inspectGoalId, setInspectGoalId] = useState(props.entityId ?? '')
  const [goalCandleData, setGoalCandleData] = useState<Record<string, unknown> | null>(null)
  const [goalCandleLoading, setGoalCandleLoading] = useState(false)
  const [goalCandleError, setGoalCandleError] = useState<string | null>(null)
  const [releaseBusy, setReleaseBusy] = useState<string | null>(null)
  const [releaseFeedback, setReleaseFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)
  const inspectAbortRef = useRef<AbortController | null>(null)

  const loadLedger = useCallback(async (reason: 'mount' | 'manual' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const obs = await resourceCache.fetch<CandleLedgerData>(
      'work:candle:ledger',
      async (signal) => {
        const res = await apiGetV2<unknown>('/api/v1/candle/ledger?limit=100', { signal })
        if (!res.ok) return res
        const decoded = decodeCandleLedger(res.value)
        if (!decoded.ok) {
          return err({
            kind: 'decode',
            status: 200,
            code: 'candle_decode_error',
            message: decoded.error,
            retryable: false,
          })
        }
        return ok(decoded.value)
      },
      { ttlMs: 15_000, topics: ['candle', 'goals'], reason },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      setLedger(obs.data)
      markViewSynced()
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [])

  useEffect(() => {
    void loadLedger('mount')
  }, [loadLedger])

  const inspectGoalCandle = useCallback(async (goalIdRaw: string, externalSignal?: AbortSignal) => {
    const goalId = goalIdRaw.trim()
    if (!goalId) return
    inspectAbortRef.current?.abort()
    const controller = new AbortController()
    inspectAbortRef.current = controller
    const signal = externalSignal ?? controller.signal

    setGoalCandleLoading(true)
    setGoalCandleError(null)
    setGoalCandleData(null)
    const wsRes = await readWorkspacePrecondition(signal)
    if (signal.aborted) return
    const params = new URLSearchParams({ goal_id: goalId })
    if (wsRes.ok) {
      params.set('expected_base_path', wsRes.value.base_path)
      params.set('expected_masc_root', wsRes.value.masc_root)
    }
    const res = await apiGet<Record<string, unknown>>(`/api/v1/dashboard/goals/candle?${params.toString()}`, { signal })
    if (signal.aborted) return
    setGoalCandleLoading(false)
    if (!res.ok) {
      setGoalCandleError(res.error.message)
      return
    }
    setGoalCandleData(res.value)
  }, [])

  useEffect(() => {
    if (props.entityId) {
      const controller = new AbortController()
      setInspectGoalId(props.entityId)
      void inspectGoalCandle(props.entityId, controller.signal)
      return () => {
        controller.abort()
      }
    }
    return undefined
  }, [props.entityId, inspectGoalCandle])

  const handleReleaseHold = async (goalId: string) => {
    const trimmed = goalId.trim()
    if (!trimmed) return
    setReleaseBusy(trimmed)
    setReleaseFeedback(null)
    const res = await apiMutate<Record<string, unknown>>(
      'POST',
      '/api/v1/dashboard/goals/candle/hold/release',
      { goal_id: trimmed },
    )
    setReleaseBusy(null)
    if (!res.ok) {
      setReleaseFeedback({ kind: 'err', message: `보류 해제 실패 (${trimmed}): ${res.error.message}` })
      return
    }
    setReleaseFeedback({
      kind: 'ok',
      message: `Goal ${trimmed} Candle 지급 보류 해제됨 (${String(res.value.outcome ?? 'released')})`,
    })
    resourceCache.invalidateTopic('candle')
    await loadLedger('manual')
    if (inspectGoalId.trim() === trimmed) {
      await inspectGoalCandle(trimmed)
    }
  }

  const chartData = useMemo<uPlot.AlignedData>(() => {
    if (!ledger) return [[], [], []]
    const series = buildCandleTrendSeries(ledger)
    return [series.timestamps, series.cumulativeIssued, series.decayedSupply]
  }, [ledger])

  const decayRatioPct = useMemo(() => {
    if (!ledger) return null
    const issued = ledger.supply.issuedMilli
    const circ = ledger.supply.circulatingMilli
    if (issued === null || circ === null || issued <= 0) return null
    return Math.max(0, Math.min(100, Math.round((circ / issued) * 100)))
  }, [ledger])

  const leaderboardColumns = useMemo<readonly DataTableColumn<CandleBalanceRow>[]>(() => [
    {
      id: 'keeper',
      header: 'Keeper',
      sortable: true,
      sortValue: (r) => r.keeper,
      cell: (r) => html`<${KeeperBadge} id=${r.keeper} portrait=${true} size="sm" />`,
    },
    {
      id: 'decayed',
      header: '감쇠 잔액 (Candle)',
      numeric: true,
      sortable: true,
      sortValue: (r) => r.decayedMilli ?? -1,
      observed: (r) => r.decayedMilli === null ? observedAbsent() : observedValue(r.decayedMilli),
      formatValue: (v) => formatMilliCandles(v),
    },
    {
      id: 'raw',
      header: '원장 잔액 (Candle)',
      numeric: true,
      sortable: true,
      sortValue: (r) => r.balanceMilli,
      observed: (r) => observedValue(r.balanceMilli),
      formatValue: (v) => formatMilliCandles(v),
    },
    {
      id: 'owned',
      header: '보유 장신구',
      numeric: true,
      sortable: true,
      sortValue: (r) => r.ownedItems.length,
      observed: (r) => observedValue(r.ownedItems.length),
    },
    {
      id: 'equipped',
      header: '장착 슬롯',
      cell: (r) => {
        const activeSlots = Object.entries(r.equipped)
          .filter(([, v]) => v !== null)
          .map(([k, v]) => `${k}:${v}`)
        return activeSlots.length > 0
          ? html`<span class="mono wk-sub-id">${activeSlots.join(', ')}</span>`
          : html`<span class="dtable-absent">없음</span>`
      },
    },
    {
      id: 'lastEvent',
      header: '최근 변동',
      accessor: (r) => formatRelativeTime(r.lastEventUnix),
    },
  ], [])

  const isMissingLedger = ledger?.ledgerState === 'missing'

  return html`
    <div class="wk-scroll-body">
      <div class="wk-toolbar">
        <div>
          <span class="wk-badge wk-badge--brass">Candle Economy</span>
          <span class="wk-caption-inline">
            Goal 완료 보상 화폐 · 초상화 장신구 전용 (constitution.xml)
          </span>
        </div>
        <button type="button" class="btn-ghost" onClick=${() => void loadLedger('manual')}>새로고침</button>
      </div>

      ${loadError && html`<div class="wk-notice wk-notice--err" role="alert">${loadError}</div>`}
      ${ledger?.balanceError && html`<div class="wk-notice wk-notice--warn" role="alert">잔액 계산 오류: ${ledger.balanceError}</div>`}
      ${loading && !ledger && html`<span class="dtable-absent">Candle 원장 불러오는 중…</span>`}

      ${ledger && html`
        <div class="ov-kpis">
          <div class="ov-kpi">
            <div class="ov-kpi-k">유통량 (Circulating)</div>
            <div class="ov-kpi-v volt">${isMissingLedger ? '없음' : formatMilliCandles(ledger.supply.circulatingMilli)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">누적 발행 (Issued)</div>
            <div class="ov-kpi-v">${isMissingLedger ? '없음' : formatMilliCandles(ledger.supply.issuedMilli)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">소각량 (Burned)</div>
            <div class="ov-kpi-v">${isMissingLedger ? '없음' : formatMilliCandles(ledger.supply.burnedMilli)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">참여 Keeper</div>
            <div class="ov-kpi-v">${isMissingLedger ? '없음' : String(ledger.supply.activeKeepers)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">원장 이벤트</div>
            <div class="ov-kpi-v">${String(ledger.totalEvents)}</div>
          </div>
        </div>

        <div class="wk-2col">
          <${UPlotChart}
            id="candle-supply-trend"
            title="Decayed Supply vs Cumulative Issuance"
            subtitle=${html`<span class="mono wk-sub-id">events: ${ledger.recentEvents.length}</span>`}
            data=${chartData}
            series=${CANDLE_SERIES}
            height=${210}
            emptyLabel="발행/감쇠 추이 이벤트가 아직 없습니다."
          />

          <section class="wk-section" aria-label="반감기 감쇠 정책">
            <div class="wk-section-head">
              <h3 class="wk-section-title">Half-Life Decay Policy</h3>
              <span class=${`wk-badge ${ledger.policy.configuration === 'enabled' ? 'wk-badge--brass' : 'wk-badge--idle'}`}>
                ${ledger.policy.configuration} · ${ledger.policy.pricingMode}
              </span>
            </div>
            ${ledger.policy.disabledReason && html`
              <div class="wk-notice wk-notice--warn">비활성 사유: ${ledger.policy.disabledReason}</div>
            `}
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">감쇠 모드</span>
                <span class="wk-kv-v">${ledger.policy.halfLifeMode}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">반감기</span>
                <span class="wk-kv-v tnum">
                  ${ledger.policy.halfLifeHours !== null
                    ? `${ledger.policy.halfLifeHours}h`
                    : ledger.policy.halfLifeSec !== null
                      ? `${Math.round(ledger.policy.halfLifeSec)}s`
                      : '없음'}
                </span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">잔존 비율 (Circulating / Issued)</span>
                <span class="wk-kv-v tnum">${decayRatioPct === null ? '없음' : `${decayRatioPct}%`}</span>
              </div>
            </div>
            <progress
              class="wk-gauge"
              value=${decayRatioPct ?? 0}
              max="100"
              aria-label="유통 잔존 게이지"
            />
          </section>
        </div>

        <section class="wk-section" aria-label="Keeper Candle 리더보드">
          <div class="wk-section-head">
            <h3 class="wk-section-title">Keeper Candle Leaderboard (${ledger.balances.length})</h3>
          </div>
          <${DataTable}
            data=${ledger.balances}
            columns=${leaderboardColumns}
            getRowId=${(r: CandleBalanceRow) => r.keeper}
            caption="Keeper별 Candle 원장 잔액 및 감쇠 잔액"
            emptyLabel="잔액이 기록된 Keeper가 없습니다."
          />
        </section>

        <section class="wk-section" aria-label="지급 진단 및 보류 해제">
          <div class="wk-section-head">
            <h3 class="wk-section-title">Unattributed / Backlog-Fenced Diagnostics & Hold Release</h3>
            <div class="wk-chips">
              <span class="wk-badge wk-badge--warn">Held Windows: ${ledger.diagnostics.heldWindowsCount}</span>
              <span class="wk-badge wk-badge--err">Unattributed: ${ledger.diagnostics.unattributedCount}</span>
              <span class="wk-badge wk-badge--idle">Backlog Fenced: ${ledger.diagnostics.backlogFencedCount}</span>
              <span class="wk-badge wk-badge--idle">0-Task Goals: ${ledger.diagnostics.zeroLinkedTasksGoals}</span>
            </div>
          </div>

          ${releaseFeedback && html`
            <div class=${`wk-notice wk-notice--${releaseFeedback.kind}`} role="status">
              ${releaseFeedback.message}
            </div>
          `}

          <div class="wk-row-wrap">
            <input
              type="text"
              class="wk-input wk-flex-input"
              placeholder="Goal ID로 지급 상태 조회 (GET /api/v1/dashboard/goals/candle)…"
              value=${inspectGoalId}
              onInput=${(e: Event) => setInspectGoalId((e.target as HTMLInputElement).value)}
              aria-label="Goal Candle 조회 ID"
            />
            <button
              type="button"
              class="btn-ghost"
              disabled=${goalCandleLoading || !inspectGoalId.trim()}
              onClick=${() => void inspectGoalCandle(inspectGoalId)}
            >
              ${goalCandleLoading ? '조회 중…' : 'Goal 지급 관측'}
            </button>
            <button
              type="button"
              class="wk-btn-warn"
              disabled=${releaseBusy !== null || !inspectGoalId.trim()}
              onClick=${() => void handleReleaseHold(inspectGoalId)}
            >
              ${releaseBusy ? '해제 중…' : 'Hold Release 실행'}
            </button>
          </div>

          ${goalCandleError && html`<div class="wk-notice wk-notice--err" role="alert">${goalCandleError}</div>`}
          ${goalCandleData && html`
            <pre class="wk-code-preview">${JSON.stringify(goalCandleData, null, 2)}</pre>
          `}

          ${ledger.diagnostics.items.length === 0
            ? html`<span class="dtable-absent">현재 진단 경고가 없습니다.</span>`
            : html`
                <div class="wk-stack-2">
                  ${ledger.diagnostics.items.map((item) => html`
                    <div key=${`${item.goalId}-${item.kind}-${item.atUnix}`} class="wk-diag-row">
                      <div class="wk-diag-main">
                        <div class="wk-diag-title">
                          <span class=${`wk-badge ${item.kind === 'candidate_window_held' ? 'wk-badge--warn' : 'wk-badge--err'}`}>
                            ${item.kind}
                          </span>
                          <strong>${item.title ?? item.goalId}</strong>
                          <span class="mono wk-sub-id">${item.goalId}</span>
                        </div>
                        <div class="wk-diag-hint">
                          ${item.diagnosticHint || item.observation}
                        </div>
                      </div>
                      <div class="wk-actions">
                        <button
                          type="button"
                          class="btn-ghost"
                          onClick=${() => {
                            setInspectGoalId(item.goalId)
                            void inspectGoalCandle(item.goalId)
                          }}
                        >
                          관측
                        </button>
                        ${item.kind === 'candidate_window_held' && html`
                          <button
                            type="button"
                            class="wk-btn-warn"
                            disabled=${releaseBusy !== null}
                            onClick=${() => void handleReleaseHold(item.goalId)}
                          >
                            Hold Release
                          </button>
                        `}
                      </div>
                    </div>
                  `)}
                </div>
              `}
        </section>
      `}
    </div>
  `
}
