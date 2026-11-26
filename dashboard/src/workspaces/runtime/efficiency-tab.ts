/**
 * Runtime L1 Tab 2: Efficiency & Cache
 *
 * - 4-Panel Synchronized UPlotChart Feedback-Loop Suite (shared `masc-telemetry` crosshair,
 *   synced to global `timeWindow` 24h | 7d | 30d):
 *   1. Prompt Cache Hit % & Savings (/api/v1/dashboard/cache-stats + /api/v1/models/metrics)
 *   2. Token Velocity vs Spend (dual series; live SSE via acquireViewStream('runtime-efficiency')
 *      ONLY when timeWindow === '24h'; snapshot on 7d | 30d per #26 SRE #3!)
 *   3. 429 / Quota Cooldown Pressure (debounced ResourceCache snapshot invalidated by Observer SSE —
 *      NEVER opens a 2nd concurrent view-scoped SSE!)
 *   4. Tool Error Rate & Exact-Output Pass % (linked 1-click to /runtime/tools & /runtime/lanes)
 * - Virtualized DataTable of Keeper Spend & Prompt Cache Outcomes (/api/v1/dashboard/keeper-costs
 *   joined with /api/v1/keeper-efficiency).
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import {
  acquireViewStream,
  apiGet,
  authSession,
  extractObserverTopics,
  formatObserved,
  isEpochCurrent,
  markViewSynced,
  observedAbsent,
  observedUnreported,
  observedValue,
  observerSseInstanceId,
  resourceCache,
  sessionEpoch,
  subscribeObserverFrames,
  subscribeObserverReconnect,
  subscribeObserverResync,
  timeWindow,
  timeWindowProviderDays,
  type Observed,
  type TimeWindow,
} from '../../core'
import { DataTable, UPlotChart, type DataTableColumn, type UPlotSeriesSpec } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import { isAdminLockedForSession } from '../../routes/router'
import {
  buildUsageHistoryChartData,
} from './quotas-tab'
import {
  decodeKeeperCostsPayload,
  decodeKeeperEfficiencyPayload,
  decodeModelsMetricsPayload,
  decodeToolMetricsSeriesPayload,
  formatCompactNumber,
  formatMs,
  formatPercent,
  formatUsd,
  loadLaneRunsPage,
  loadProviderUsageHistory,
  localUtcOffsetMin,
  openViewSseStream,
  snapshotUnavailableReason,
  toObservedNumber,
  type CacheStatsPayload,
  type KeeperCostsPayload,
  type KeeperEfficiencyPayload,
  type ModelsMetricsPayload,
  type ProviderUsageHistoryResponse,
  type ToolMetricsSeriesPayload,
  type WorkspaceViewProps,
} from './types'
import type { LaneRunsResponse } from '../../api/dashboard-exact-lane-runs'
import { laneRunPassReading } from './lane-run-view'

function windowToModelsParams(win: TimeWindow): { windowMinutes: number; bucketMinutes: number; sinceHours: number; bucket: 'hour' | 'day' } {
  switch (win) {
    case '24h': return { windowMinutes: 1440, bucketMinutes: 60, sinceHours: 24, bucket: 'hour' }
    case '7d': return { windowMinutes: 10_080, bucketMinutes: 360, sinceHours: 168, bucket: 'day' }
    case '30d': return { windowMinutes: 10_080, bucketMinutes: 720, sinceHours: 720, bucket: 'day' }
  }
}

const CACHE_SERIES: readonly UPlotSeriesSpec[] = [
  { label: '프롬프트 캐시 적중률 (%)', colorToken: '--ok-fg', width: 2, fillAlpha: 0.16, unit: '%' },
]

const VELOCITY_SPEND_SERIES: readonly UPlotSeriesSpec[] = [
  { label: '처리량 (요청/버킷)', colorToken: '--info-fg', width: 2, fillAlpha: 0.12 },
  { label: '비용 ($ × 100 센트)', colorToken: '--brass-1', width: 2, unit: '¢' },
]

const COOLDOWN_SERIES: readonly UPlotSeriesSpec[] = [
  { label: '피크 할당량 사용률 (%)', colorToken: '--warn-fg', width: 2, fillAlpha: 0.14, unit: '%' },
  { label: '429 / 소진 카운트', colorToken: '--err-fg', width: 1.75, dash: [4, 3] },
]

const TOOL_EXACT_SERIES: readonly UPlotSeriesSpec[] = [
  { label: '도구 오류율 (%)', colorToken: '--err-fg', width: 2, fillAlpha: 0.12, unit: '%' },
  { label: '도구 호출량 (÷10)', colorToken: '--info-fg', width: 1.5, dash: [3, 3] },
]

interface AggregatedModelBucket {
  readonly ts: number
  readonly entries: number
  readonly costUsd: number
  readonly cacheHitPct: number | null
}

function aggregateModelBuckets(payload: ModelsMetricsPayload | null): readonly AggregatedModelBucket[] {
  if (!payload) return []
  const map = new Map<number, { entries: number; cost: number; cacheWeightedSum: number; cacheWeight: number }>()
  for (const m of payload.models) {
    for (const b of m.buckets) {
      const cur = map.get(b.ts_start) ?? { entries: 0, cost: 0, cacheWeightedSum: 0, cacheWeight: 0 }
      cur.entries += b.entry_count
      if (typeof b.total_cost_usd === 'number' && Number.isFinite(b.total_cost_usd)) {
        cur.cost += b.total_cost_usd
      }
      if (typeof b.cache_hit_ratio === 'number' && Number.isFinite(b.cache_hit_ratio)) {
        const weight = b.entry_count > 0 ? b.entry_count : 1
        cur.cacheWeightedSum += b.cache_hit_ratio * 100 * weight
        cur.cacheWeight += weight
      }
      map.set(b.ts_start, cur)
    }
  }
  return [...map.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([ts, agg]) => ({
      ts,
      entries: agg.entries,
      costUsd: agg.cost,
      cacheHitPct: agg.cacheWeight > 0 ? Number((agg.cacheWeightedSum / agg.cacheWeight).toFixed(1)) : null,
    }))
}

interface JoinedKeeperSpendRow {
  readonly keeper: string
  readonly turns: Observed<number>
  readonly totalTokens: Observed<number>
  readonly cacheHitPct: Observed<number>
  readonly spendUsd: Observed<number>
  readonly toolCalls: Observed<number>
  readonly toolErrors: Observed<number>
  readonly p95LatencyMs: Observed<number>
}

export function EfficiencyTab(props: WorkspaceViewProps) {
  const win = timeWindow.value
  const session = authSession.value
  const isSingleUser = session.kind === 'single_user_local'
  const isMultiAccountSignedIn = session.kind === 'multi_account_signed_in'
  const adminLocked = isAdminLockedForSession('admin', session)
  const sseInstanceId = isSingleUser ? observerSseInstanceId.value : null
  const epoch = sessionEpoch.value
  const params = windowToModelsParams(win)
  const providerDays = timeWindowProviderDays(win)

  const [liveMetrics, setLiveMetrics] = useState<ModelsMetricsPayload | null>(null)
  const [streamLive, setStreamLive] = useState(false)
  const [streamError, setStreamError] = useState<string | null>(null)
  const [streamDecodeError, setStreamDecodeError] = useState<string | null>(null)
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const utcOffsetMin = localUtcOffsetMin()

  const modelsKey = `runtime:models-metrics:${win}`
  const cacheStatsKey = 'runtime:cache-stats'
  const historyKey = `runtime:provider-usage-history:${providerDays}`
  const toolSeriesKey = `runtime:tool-series-snap:${win}`
  const exactRunsKey = 'runtime:exact-runs-snap'
  const costsKey = 'runtime:keeper-costs:24h'
  const effKey = 'runtime:keeper-efficiency'

  const modelsObs = resourceCache.observe<ModelsMetricsPayload>(modelsKey).value
  const cacheObs = resourceCache.observe<CacheStatsPayload>(cacheStatsKey).value
  const historyObs = resourceCache.observe<ProviderUsageHistoryResponse>(historyKey).value
  const toolSeriesObs = resourceCache.observe<ToolMetricsSeriesPayload>(toolSeriesKey).value
  const exactObs = resourceCache.observe<LaneRunsResponse>(exactRunsKey).value
  const costsObs = resourceCache.observe<KeeperCostsPayload>(costsKey).value
  const effObs = resourceCache.observe<KeeperEfficiencyPayload>(effKey).value

  const loadSnapshots = (reason: 'mount' | 'sse' | 'manual' = 'mount') => {
    const curSession = authSession.peek()
    const singleLocal = curSession.kind === 'single_user_local'
    const multiSignedIn = curSession.kind === 'multi_account_signed_in'
    if (!singleLocal && !multiSignedIn) return

    const startEpoch = epoch
    const jobs: Promise<unknown>[] = [
      resourceCache.fetch<CacheStatsPayload>(
        cacheStatsKey,
        (signal) => apiGet<CacheStatsPayload>('/api/v1/dashboard/cache-stats', { signal }),
        { ttlMs: 15_000, topics: ['cache_stats', 'model_metrics', 'telemetry'], reason },
      ),
    ]
    if (!isAdminLockedForSession('admin', curSession)) {
      jobs.push(
        resourceCache.fetch<LaneRunsResponse>(
          exactRunsKey,
          (signal) => loadLaneRunsPage({ limit: 50 }, signal),
          { ttlMs: 20_000, topics: ['exact_lane_runs', 'verification_requests'], reason },
        ),
      )
    }
    if (singleLocal) {
      jobs.push(
        resourceCache.fetch<ModelsMetricsPayload>(
          modelsKey,
          (signal) => apiGet<ModelsMetricsPayload>(
            `/api/v1/models/metrics?window=${params.windowMinutes}&bucket_min=${params.bucketMinutes}`,
            { signal, decode: decodeModelsMetricsPayload },
          ),
          { ttlMs: 20_000, topics: ['model_metrics', 'telemetry'], reason },
        ),
        resourceCache.fetch<ProviderUsageHistoryResponse>(
          historyKey,
          (signal) => loadProviderUsageHistory(providerDays, signal),
          { ttlMs: 30_000, topics: ['provider_usage', 'runtime_resolved'], reason },
        ),
        resourceCache.fetch<ToolMetricsSeriesPayload>(
          toolSeriesKey,
          (signal) => apiGet<ToolMetricsSeriesPayload>(
            `/api/v1/tool-metrics/series?since_hours=${params.sinceHours}&bucket=${params.bucket}&utc_offset_min=${utcOffsetMin}`,
            { signal, decode: decodeToolMetricsSeriesPayload },
          ),
          { ttlMs: 20_000, topics: ['tool_metrics', 'telemetry'], reason },
        ),
        // Server enforces keeper_costs_max_window_minutes = 1440 (rejects >1440 with HTTP 400)
        resourceCache.fetch<KeeperCostsPayload>(
          costsKey,
          (signal) => apiGet<KeeperCostsPayload>('/api/v1/dashboard/keeper-costs?window=1440', {
            signal,
            decode: decodeKeeperCostsPayload,
          }),
          { ttlMs: 20_000, topics: ['keeper_costs', 'model_metrics', 'keeper_turn_complete', 'cost'], reason },
        ),
        resourceCache.fetch<KeeperEfficiencyPayload>(
          effKey,
          (signal) => apiGet<KeeperEfficiencyPayload>('/api/v1/keeper-efficiency', {
            signal,
            decode: decodeKeeperEfficiencyPayload,
          }),
          { ttlMs: 60_000, topics: ['keeper_efficiency', 'model_metrics', 'keeper_turn_complete', 'cost'], reason },
        ),
      )
    }
    void Promise.all(jobs).then(() => {
      if (isEpochCurrent(startEpoch)) markViewSynced()
    })
  }

  // Initial + window-change snapshots
  useEffect(() => {
    setLiveMetrics(null)
    setStreamError(null)
    loadSnapshots('mount')
  }, [win, epoch, session.kind, adminLocked])

  // Strict 2+1 SSE invariant (#26 SRE #3):
  // Acquire single view-scoped SSE ONLY on '24h' once observer x-masc-sse-instance-id is populated.
  useEffect(() => {
    setStreamDecodeError(null)
    if (win !== '24h' || !sseInstanceId) {
      setStreamLive(false)
      return
    }
    const handle = acquireViewStream('runtime-efficiency', (signal) => {
      openViewSseStream(
        '/api/v1/models/metrics/stream?window=1440&bucket_min=60',
        signal,
        (frame) => {
          if (frame.data && typeof frame.data === 'object') {
            const payload = frame.data as Record<string, unknown>
            if (typeof payload.error === 'string' && payload.error.trim().length > 0) {
              setStreamLive(false)
              setStreamError(payload.error.trim())
              return
            }
            if ('models' in payload) {
              try {
                const decoded = decodeModelsMetricsPayload(frame.data)
                setLiveMetrics(decoded)
                setStreamError(null)
                setStreamDecodeError(null)
                setStreamLive(true)
              } catch (error) {
                setStreamDecodeError(error instanceof Error ? error.message : String(error))
              }
            }
          }
        },
        (status, detail) => {
          setStreamLive(status === 'open')
          if (status === 'error' && detail) setStreamError(detail)
        },
      )
    })
    return () => {
      handle.release()
    }
  }, [win, sseInstanceId, epoch])

  // Observer SSE debounced invalidation for secondary bands (Panel 3 & Panel 4) — ZERO 2nd view SSE
  useEffect(() => {
    const watchedTopics = new Set([
      'provider_usage',
      'tool_metrics',
      'exact_lane_runs',
      'model_metrics',
      'telemetry',
      'runtime_resolved',
      'keeper_turn_complete',
      'keeper_turns',
      'dataset_invalidation',
    ])
    const unsub = subscribeObserverFrames((frame) => {
      if (extractObserverTopics(frame).some((topic) => watchedTopics.has(topic))) {
        if (debounceTimerRef.current !== null) clearTimeout(debounceTimerRef.current)
        debounceTimerRef.current = setTimeout(() => {
          loadSnapshots('sse')
        }, 600)
      }
    })
    const recover = () => {
      if (isEpochCurrent(epoch)) loadSnapshots('sse')
    }
    const unsubReconnect = subscribeObserverReconnect(recover)
    const unsubResync = subscribeObserverResync(recover)
    return () => {
      unsub()
      unsubReconnect()
      unsubResync()
      if (debounceTimerRef.current !== null) clearTimeout(debounceTimerRef.current)
    }
  }, [win, epoch, session.kind, adminLocked])

  const effectiveModels = !isSingleUser
    ? null
    : (win === '24h' && sseInstanceId && liveMetrics)
      ? liveMetrics
      : (modelsObs.kind === 'value' ? modelsObs.data : null)
  const live = isSingleUser && win === '24h' && sseInstanceId !== null && streamLive
  const snapshotError = isSingleUser
    ? (streamError ?? (!effectiveModels ? snapshotUnavailableReason(modelsObs) : null))
    : null
  const modelsWindowLabel = win === '30d' ? '7d 상한' : win
  const seriesSource = !isSingleUser ? '○ SINGLE-USER ONLY'
    : live ? '● LIVE SSE (models/metrics/stream)'
    : streamError ? `○ STREAM ERROR (${streamError})`
    : snapshotError ? '○ UNAVAILABLE'
    : modelsObs.kind === 'loading' && !effectiveModels ? '◐ LOADING'
    : `○ SNAPSHOT (${modelsWindowLabel})`


  const buckets = useMemo(() => aggregateModelBuckets(effectiveModels), [effectiveModels])

  const cacheChartData = useMemo<uPlot.AlignedData>(() => {
    if (buckets.length === 0) return [[], []]
    return [
      buckets.map((b) => b.ts),
      buckets.map((b) => b.cacheHitPct),
    ]
  }, [buckets])

  const velocitySpendChartData = useMemo<uPlot.AlignedData>(() => {
    if (buckets.length === 0) return [[], [], []]
    return [
      buckets.map((b) => b.ts),
      buckets.map((b) => b.entries),
      buckets.map((b) => Number((b.costUsd * 100).toFixed(2))),
    ]
  }, [buckets])

  const cooldownChartData = useMemo<uPlot.AlignedData>(() => {
    if (historyObs.kind !== 'value' || historyObs.data.state === 'unavailable') return [[], [], []]
    const full = buildUsageHistoryChartData(historyObs.data.points)
    return [full[0], full[2] ?? [], full[3] ?? []]
  }, [historyObs])

  const toolChartData = useMemo<uPlot.AlignedData>(() => {
    if (toolSeriesObs.kind !== 'value') return [[], [], []]
    const ts: number[] = []
    const errRate: (number | null)[] = []
    const callsScaled: number[] = []
    for (const b of toolSeriesObs.data.buckets ?? []) {
      ts.push(b.start)
      const settled = Math.max(0, b.call_count - (b.deferred_count ?? 0))
      const rate = settled > 0 ? Number(((b.failure_count / settled) * 100).toFixed(1)) : null
      errRate.push(rate)
      callsScaled.push(Number((b.call_count / 10).toFixed(1)))
    }
    return [ts, errRate, callsScaled]
  }, [toolSeriesObs])

  // KPI calculations (honest Observed<T>)
  const kpis = useMemo(() => {
    let totalIn = 0
    let totalCacheRead = 0
    let totalCost: number | null = null
    if (effectiveModels) {
      for (const m of effectiveModels.models ?? []) {
        if (m.cached_input) {
          totalIn += m.cached_input.input_tokens
          totalCacheRead += m.cached_input.cache_read_tokens
        } else if (typeof m.total_input_tokens === 'number' && typeof m.total_cache_read_tokens === 'number') {
          totalIn += m.total_input_tokens
          totalCacheRead += m.total_cache_read_tokens
        }
        if (typeof m.total_cost_usd === 'number') {
          totalCost = (totalCost ?? 0) + m.total_cost_usd
        }
      }
    }
    const cacheHitObs: Observed<number> = totalIn > 0
      ? observedValue(Math.min(100, (totalCacheRead / totalIn) * 100))
      : observedUnreported()
    const spendObs: Observed<number> = totalCost !== null ? observedValue(totalCost) : observedUnreported()

    const exactRuns = !adminLocked && exactObs.kind === 'value' ? (exactObs.data.runs ?? []) : []
    const readings = exactRuns.map(laneRunPassReading)
    const terminalExact = readings.filter((reading) => reading !== 'running')
    const passedExact = terminalExact.filter((reading) => reading === 'passed')
    const exactPassObs: Observed<number> = terminalExact.length > 0
      ? observedValue((passedExact.length / terminalExact.length) * 100)
      : observedAbsent()

    const toolTotal = toolSeriesObs.kind === 'value' ? toolSeriesObs.data.total : null
    const settledTools = toolTotal ? Math.max(0, toolTotal.call_count - (toolTotal.deferred_count ?? 0)) : 0
    const toolErrObs: Observed<number> = toolTotal && settledTools > 0
      ? observedValue((toolTotal.failure_count / settledTools) * 100)
      : toolTotal
        ? observedUnreported()
        : observedAbsent()

    return { cacheHitObs, spendObs, exactPassObs, toolErrObs }
  }, [effectiveModels, exactObs, toolSeriesObs, adminLocked])

  const joinedKeepers = useMemo<readonly JoinedKeeperSpendRow[]>(() => {
    const map = new Map<string, JoinedKeeperSpendRow>()
    const effByName = new Map<string, KeeperEfficiencyPayload['keepers'][number]>()
    if (effObs.kind === 'value') {
      for (const row of effObs.data.keepers ?? []) effByName.set(row.keeper, row)
    }

    const resolveEffCacheHitPct = (
      eff: KeeperEfficiencyPayload['keepers'][number] | undefined,
    ): Observed<number> => {
      if (!eff) return observedUnreported()
      if (typeof eff.cache_hit_pct === 'number' && Number.isFinite(eff.cache_hit_pct)) {
        return observedValue(Math.min(100, Math.max(0, eff.cache_hit_pct)))
      }
      if (eff.cache_hit_pct === null) {
        return observedUnreported()
      }
      if (typeof eff.cache_read_tokens === 'number' && eff.input_tokens > 0) {
        return observedValue(Math.min(100, (eff.cache_read_tokens / eff.input_tokens) * 100))
      }
      return observedUnreported()
    }

    if (costsObs.kind === 'value') {
      for (const c of costsObs.data.keepers ?? []) {
        const eff = effByName.get(c.keeper_name)
        map.set(c.keeper_name, {
          keeper: c.keeper_name,
          turns: eff ? observedValue(eff.turns) : observedUnreported(),
          totalTokens: c.tokens_reported_samples > 0 && c.total_tokens !== null
            ? observedValue(c.total_tokens)
            : observedUnreported(),
          cacheHitPct: resolveEffCacheHitPct(eff),
          spendUsd: c.cost_reported_samples > 0 && c.total_cost_usd !== null
            ? observedValue(c.total_cost_usd)
            : observedUnreported(),
          toolCalls: eff ? observedValue(eff.calls) : observedUnreported(),
          toolErrors: eff ? observedValue(eff.failed) : observedUnreported(),
          p95LatencyMs: toObservedNumber(c.p95_latency_ms, true),
        })
      }
    }

    if (effObs.kind === 'value') {
      for (const eff of effObs.data.keepers ?? []) {
        if (map.has(eff.keeper)) continue
        // Keep 24h spend/token/p95 columns strictly scoped to the 24h cost ledger
        // instead of mixing MTD totals or fabricating $0.00 for unreported subscription spend.
        map.set(eff.keeper, {
          keeper: eff.keeper,
          turns: observedValue(eff.turns),
          totalTokens: observedUnreported(),
          cacheHitPct: resolveEffCacheHitPct(eff),
          spendUsd: observedUnreported(),
          toolCalls: observedValue(eff.calls),
          toolErrors: observedValue(eff.failed),
          p95LatencyMs: observedUnreported(),
        })
      }
    }

    return [...map.values()]
  }, [costsObs, effObs])

  const keeperColumns = useMemo<readonly DataTableColumn<JoinedKeeperSpendRow>[]>(() => [
    {
      id: 'keeper',
      header: 'Keeper',
      sortable: true,
      sortValue: (r) => r.keeper,
      cell: (r) => html`<${KeeperBadge} id=${r.keeper} size="sm" />`,
    },
    {
      id: 'turns',
      header: '월간 턴',
      numeric: true,
      sortable: true,
      observed: (r) => r.turns,
      formatValue: (v) => formatCompactNumber(Number(v)),
    },
    {
      id: 'tokens',
      header: '토큰 (24h)',
      numeric: true,
      sortable: true,
      observed: (r) => r.totalTokens,
      formatValue: (v) => formatCompactNumber(Number(v)),
    },
    {
      id: 'cacheHit',
      header: '월간 캐시 %',
      numeric: true,
      sortable: true,
      observed: (r) => r.cacheHitPct,
      formatValue: (v) => formatPercent(Number(v)),
    },
    {
      id: 'spend',
      header: '비용 (24h USD)',
      numeric: true,
      sortable: true,
      observed: (r) => r.spendUsd,
      formatValue: (v) => formatUsd(Number(v)),
    },
    {
      id: 'tools',
      header: '월간 도구 호출',
      numeric: true,
      sortable: true,
      observed: (r) => r.toolCalls,
      formatValue: (v) => formatCompactNumber(Number(v)),
    },
    {
      id: 'errors',
      header: '월간 도구 실패',
      numeric: true,
      sortable: true,
      observed: (r) => r.toolErrors,
      formatValue: (v) => formatCompactNumber(Number(v)),
    },
    {
      id: 'p95',
      header: 'p95 지연 (24h)',
      numeric: true,
      sortable: true,
      observed: (r) => r.p95LatencyMs,
      formatValue: (v) => formatMs(Number(v)),
    },
  ], [])

  const cacheStats = cacheObs.kind === 'value' ? cacheObs.data : null

  return html`
    <div class="ov" data-testid="runtime-efficiency-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · EFFICIENCY & CACHE</span>
          <h1>프롬프트 캐시 · 토큰 속도 · 4패널 상관 피드백 루프</h1>
          <p class="ov-sub">
            공유 크로스헤어 (<span class="mono">masc-telemetry</span>) · 2+1 SSE 규율 준수
          </p>
        </div>
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          <button type="button" class="btn-ghost" onClick=${() => loadSnapshots('manual')}>새로고침</button>
        </div>
      </header>

      ${isMultiAccountSignedIn && html`
        <div class="wka-card" data-testid="efficiency-mode-notice" role="status" style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
          멀티 계정 모드에서는 API 캐시 통계와 Exact-Output 지표(관리자 전용)만 브리지됩니다. 모델·도구·Keeper 비용 시계열은 single_user 모드에서 제공됩니다.
        </div>
      `}

      ${streamDecodeError && html`
        <div class="ap-error" role="alert">실시간 모델 지표 디코드 오류: ${streamDecodeError}</div>
      `}

      <section class="ov-kpis" aria-label="효율성 핵심 지표">
        <div class="ov-kpi">
          <div class="ov-kpi-k">플리트 프롬프트 캐시 적중률</div>
          <div class="ov-kpi-v ok">${formatObserved(kpis.cacheHitObs, (v) => formatPercent(v))}</div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">기간 비용 (${modelsWindowLabel})</div>
          <div class="ov-kpi-v volt">${formatObserved(kpis.spendObs, (v) => formatUsd(v))}</div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">도구 오류율</div>
          <div class=${`ov-kpi-v ${kpis.toolErrObs.kind === 'value' && kpis.toolErrObs.data > 5 ? 'bad' : ''}`}>
            ${formatObserved(kpis.toolErrObs, (v) => formatPercent(v))}
          </div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">Exact-Output 통과율</div>
          <div class=${`ov-kpi-v ${adminLocked ? '' : 'ok'}`} data-testid="efficiency-exact-pass-kpi">
            ${adminLocked ? '관리자 전용' : formatObserved(kpis.exactPassObs, (v) => formatPercent(v))}
          </div>
        </div>
      </section>

      <!-- 4-Panel Synchronized uPlot Suite (balanced 2x2 on >=1024px) -->
      <section
        class="uplot-grid-2x2"
        aria-label="4패널 동기화 텔레메트리 차트"
      >
        <!-- Panel 1: Prompt Cache Hit % & Savings -->
        <${UPlotChart}
          id="eff-panel-1-cache"
          title="1. Prompt Cache Hit % & 대시보드 캐시"
          subtitle=${cacheStats
            ? html`<span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                API 캐시 적중 ${(cacheStats.hit_ratio * 100).toFixed(1)}% · 항목 ${cacheStats.entries}/${cacheStats.max_entries} (신선 ${cacheStats.fresh})
              </span>`
            : html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>스냅샷</span>`}
          data=${cacheChartData}
          series=${CACHE_SERIES}
          height=${190}
          syncCrosshair=${true}
          emptyLabel="캐시 적중률 버킷 없음"
        />

        <!-- Panel 2: Token Velocity vs Spend -->
        <${UPlotChart}
          id="eff-panel-2-velocity"
          title="2. Token Velocity vs Spend"
          subtitle=${html`<span
            class="mono"
            data-testid="efficiency-stream-badge"
            style=${{ fontSize: 'var(--fs-11)', color: live ? 'var(--ok-fg)' : 'var(--fg-3)' }}
          >
            ${seriesSource}
          </span>`}
          data=${velocitySpendChartData}
          series=${VELOCITY_SPEND_SERIES}
          height=${190}
          syncCrosshair=${true}
          emptyLabel=${snapshotError ? `모델 지표 조회 실패: ${snapshotError}`
            : modelsObs.kind === 'loading' ? '모델 지표 불러오는 중…'
            : '토큰 속도/비용 버킷 없음'}
        />

        <!-- Panel 3: 429 / Quota Cooldown Pressure -->
        <${UPlotChart}
          id="eff-panel-3-cooldown"
          title="3. 429 / Quota Cooldown Pressure"
          subtitle=${html`<button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-0) var(--sp-1)', fontSize: 'var(--fs-11)' }} onClick=${() => props.onNavigate('/runtime/quotas')}>
            Quotas →
          </button>`}
          data=${cooldownChartData}
          series=${COOLDOWN_SERIES}
          height=${190}
          syncCrosshair=${true}
          emptyLabel=${historyObs.kind === 'value' && historyObs.data.state === 'unavailable'
            ? `사용량 이력 불가: ${historyObs.data.reason}`
            : '일시 중지 이력 없음'}
        />

        <!-- Panel 4: Tool Error Rate & Call Volume -->
        <${UPlotChart}
          id="eff-panel-4-tools-exact"
          title="4. Tool Error Rate & Call Volume"
          subtitle=${html`
            <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
              <button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-0) var(--sp-1)', fontSize: 'var(--fs-11)' }} onClick=${() => props.onNavigate('/runtime/tools')}>
                Tools →
              </button>
              <button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-0) var(--sp-1)', fontSize: 'var(--fs-11)' }} onClick=${() => props.onNavigate('/runtime/lanes')}>
                Lanes →
              </button>
            </div>
          `}
          data=${toolChartData}
          series=${TOOL_EXACT_SERIES}
          height=${190}
          syncCrosshair=${true}
          emptyLabel=${toolSeriesObs.kind === 'failed'
            ? `도구 시계열 조회 실패: ${toolSeriesObs.error.message}`
            : '도구 오류 시계열 없음'}
        />
      </section>

      <!-- Virtualized Keeper Spend & Prompt Cache Outcomes Table -->
      <section style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
        <div class="wka-h">
          <h3>Keeper별 24h 비용 · 월간 프롬프트 캐시 성과 (${joinedKeepers.length})</h3>
          <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            비용은 24h 상한 창 · 미보고 구독 비용은 0이 아닌 "미보고"로 표기
          </span>
        </div>
        ${(costsObs.kind === 'failed' || effObs.kind === 'failed') && html`
          <div class="ap-error" role="alert">
            ${costsObs.kind === 'failed' ? `Keeper 비용 조회 실패: ${costsObs.error.message}` : ''}
            ${costsObs.kind === 'failed' && effObs.kind === 'failed' ? ' · ' : ''}
            ${effObs.kind === 'failed' ? `Keeper 효율 조회 실패: ${effObs.error.message}` : ''}
          </div>
        `}
        <${DataTable}
          data=${joinedKeepers}
          columns=${keeperColumns}
          getRowId=${(r: JoinedKeeperSpendRow) => r.keeper}
          virtualizeThreshold=${30}
          maxHeight=${420}
          caption="Keeper 비용 및 프롬프트 캐시 효율"
          emptyLabel=${costsObs.kind === 'loading' ? '불러오는 중…' : '기록된 Keeper 비용 데이터가 없습니다.'}
        />
      </section>
    </div>
  `
}
