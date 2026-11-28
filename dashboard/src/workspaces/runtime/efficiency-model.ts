import type { ModelsMetricsPayload } from './types'

interface AggregatedModelBucket {
  readonly ts: number
  readonly entries: number
  readonly costUsd: number | null
  readonly costCoverage: 'reported' | 'partial' | 'unreported'
  readonly cacheHitPct: number | null
  readonly cacheReportedSamples: number | null
  readonly cacheExpectedSamples: number | null
  readonly cacheSource: 'paired' | 'legacy_single_model' | 'unreported'
}

export function aggregateModelBuckets(payload: ModelsMetricsPayload | null): readonly AggregatedModelBucket[] {
  if (!payload) return []
  const map = new Map<number, {
    entries: number
    cost: number
    costReports: number
    costUnknown: number
    modelBuckets: number
    pairedInputTokens: number
    pairedCacheReadTokens: number
    pairedSamples: number
    expectedSamples: number
    legacyCacheRatios: number[]
  }>()
  for (const m of payload.models) {
    for (const b of m.buckets) {
      const cur = map.get(b.ts_start) ?? {
        entries: 0,
        cost: 0,
        costReports: 0,
        costUnknown: 0,
        modelBuckets: 0,
        pairedInputTokens: 0,
        pairedCacheReadTokens: 0,
        pairedSamples: 0,
        expectedSamples: 0,
        legacyCacheRatios: [],
      }
      cur.modelBuckets += 1
      cur.entries += b.entry_count
      cur.expectedSamples += Math.max(0, b.success_count ?? b.entry_count)
      if (typeof b.total_cost_usd === 'number' && Number.isFinite(b.total_cost_usd)) {
        cur.cost += b.total_cost_usd
        cur.costReports += 1
      } else {
        cur.costUnknown += 1
      }
      if (b.cached_input) {
        cur.pairedInputTokens += b.cached_input.input_tokens
        cur.pairedCacheReadTokens += b.cached_input.cache_read_tokens
        cur.pairedSamples += b.cached_input.sample_count
      } else if (typeof b.cache_hit_ratio === 'number' && Number.isFinite(b.cache_hit_ratio)) {
        // A pre-paired wire can still give a rate for one model bucket.
        cur.legacyCacheRatios.push(Math.min(1, Math.max(0, b.cache_hit_ratio)) * 100)
      }
      map.set(b.ts_start, cur)
    }
  }
  return [...map.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([ts, agg]) => ({
      ts,
      entries: agg.entries,
      // Keep a gap if any model bucket did not report a cost. Older servers
      // may still report partial sums, so the chart describes reported cost.
      costUsd: agg.costReports > 0 && agg.costUnknown === 0 ? agg.cost : null,
      costCoverage: agg.costReports === 0 ? 'unreported' : agg.costUnknown > 0 ? 'partial' : 'reported',
      // Paired totals combine exactly across models, including partial
      // telemetry. Old wires lack those totals, so only a single model ratio
      // can be shown without inventing a cross-model weighting.
      cacheHitPct: agg.pairedInputTokens > 0
        ? Number((agg.pairedCacheReadTokens * 100 / agg.pairedInputTokens).toFixed(1))
        : agg.modelBuckets === 1 && agg.legacyCacheRatios.length === 1
          ? Number(agg.legacyCacheRatios[0]!.toFixed(1))
          : null,
      cacheReportedSamples: agg.pairedInputTokens > 0 ? agg.pairedSamples : null,
      cacheExpectedSamples: agg.pairedInputTokens > 0 ? agg.expectedSamples : null,
      cacheSource: agg.pairedInputTokens > 0
        ? 'paired'
        : agg.modelBuckets === 1 && agg.legacyCacheRatios.length === 1
          ? 'legacy_single_model'
          : 'unreported',
    }))
}

export function pairedCacheCoverage(models: ModelsMetricsPayload['models']) {
  let inputTokens = 0
  let cacheReadTokens = 0
  let reportedSamples = 0
  let expectedSamples = 0
  for (const model of models) {
    expectedSamples += Math.max(0, model.success_count ?? model.entry_count)
    const paired = model.cached_input
    if (!paired) continue
    inputTokens += paired.input_tokens
    cacheReadTokens += paired.cache_read_tokens
    reportedSamples += paired.sample_count
  }
  return {
    hitPct: inputTokens > 0 ? Math.min(100, (cacheReadTokens / inputTokens) * 100) : null,
    reportedSamples,
    expectedSamples,
  }
}

export function modelCostCoverage(models: ModelsMetricsPayload['models']) {
  let reportedUsd = 0
  let reportedSuccessModels = 0
  let successModels = 0
  let unknownSuccessModels = 0
  for (const model of models) {
    const successes = model.success_count
    if (typeof successes !== 'number' || !Number.isSafeInteger(successes) || successes < 0) {
      unknownSuccessModels += 1
      continue
    }
    if (successes === 0) continue
    successModels += 1
    if (typeof model.total_cost_usd !== 'number' || !Number.isFinite(model.total_cost_usd)) continue
    reportedUsd += model.total_cost_usd
    reportedSuccessModels += 1
  }
  return {
    reportedUsd,
    reportedSuccessModels,
    successModels,
    unknownSuccessModels,
    hasReported: reportedSuccessModels > 0,
  }
}

export function cacheBucketCoverageLabel(buckets: readonly AggregatedModelBucket[]): string {
  const pairedBuckets = buckets.filter((bucket) => bucket.cacheSource === 'paired')
  const legacyBuckets = buckets.filter((bucket) => bucket.cacheSource === 'legacy_single_model').length
  if (pairedBuckets.length > 0) {
    const reported = pairedBuckets.reduce((sum, bucket) => sum + (bucket.cacheReportedSamples ?? 0), 0)
    const expected = pairedBuckets.reduce((sum, bucket) => sum + (bucket.cacheExpectedSamples ?? 0), 0)
    return `paired 보고가 있는 구간 내 ${reported}/${expected} 샘플${legacyBuckets > 0 ? ` · 구형 단일 모델 버킷 ${legacyBuckets}개` : ''}`
  }
  if (legacyBuckets > 0) return `구형 단일 모델 비율 ${legacyBuckets}개 · 표본 커버리지 미확인`
  return 'paired 입력 없음 · 복수 모델의 구형 비율은 합산하지 않음'
}
