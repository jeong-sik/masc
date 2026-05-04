// CapabilitySummaryStrip — Spotlight KPI strip for the provider capability
// matrix page. Derives summary metrics from static data (FEATURES,
// WIRING_GAPS, ANTI_PATTERNS, BFCL_RANKINGS) and live provider overlay.
//
// Pattern: Cockpit UI Kit Spotlight KPI (Chrome.jsx lines 101-179).
// Priority cascade: high-impact wiring gaps > critical anti-patterns >
// coverage gaps > benchmark performance.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import type { VNode } from 'preact'
import {
  FEATURES,
  WIRING_GAPS,
  ANTI_PATTERNS,
  BFCL_RANKINGS,
} from './data'
import type { DashboardRuntimeProviderSnapshot } from '../../api/dashboard'
import type { KpiCellKind } from '../kpi-shared'
import { KpiStripIsland, type KpiStripIslandData } from '../kpi-strip-island'

export interface CapabilitySummaryProps {
  liveProviders?: DashboardRuntimeProviderSnapshot[]
}

interface SummaryMetric {
  label: string
  value: string
  caption?: string
  kind?: KpiCellKind
  spotlight?: boolean
}

function deriveMetrics(liveProviders: DashboardRuntimeProviderSnapshot[]): SummaryMetric[] {
  // Wiring gaps — high impact count is the most urgent signal
  const highGaps = WIRING_GAPS.filter(g => g.impact === 'high')
  const totalGaps = WIRING_GAPS.filter(g => g.impact !== 'correct').length
  const correctGaps = WIRING_GAPS.filter(g => g.impact === 'correct').length

  // Anti-patterns — critical + high risk count
  const critHigh = ANTI_PATTERNS.filter(a => a.risk === 'C' || a.risk === 'H')
  const silentFailures = ANTI_PATTERNS.filter(a => a.category === 'silent-failure')

  // Feature coverage — features where ● count < 50% of providers
  const providerCount = 13
  const lowCoverageFeatures = FEATURES.filter(f => {
    const fullCount = Object.values(f.providers).filter(v => v === '●').length
    return fullCount / providerCount < 0.5
  })

  // Best BFCL score
  const bestBfcl = BFCL_RANKINGS.length > 0 ? BFCL_RANKINGS[0] : null

  // Live providers count
  const liveCount = liveProviders.length

  // Priority: high wiring gaps > crit/high anti-patterns > low coverage
  // Spotlight picks the most urgent
  const hasUrgentGaps = highGaps.length > 0
  const hasUrgentAntiPatterns = critHigh.length > 0

  const metrics: SummaryMetric[] = []

  // Spotlight: most urgent metric
  if (hasUrgentGaps) {
    metrics.push({
      label: 'HIGH 배선 갭',
      value: String(highGaps.length),
      caption: `${totalGaps} gap · ${correctGaps} correct`,
      kind: 'err',
      spotlight: true,
    })
  } else if (hasUrgentAntiPatterns) {
    metrics.push({
      label: '위험 안티패턴',
      value: String(critHigh.length),
      caption: `C+H / ${ANTI_PATTERNS.length} total`,
      kind: 'warn',
      spotlight: true,
    })
  } else {
    metrics.push({
      label: '배선 정합',
      value: `${correctGaps}/${WIRING_GAPS.length}`,
      caption: 'wiring verified',
      kind: 'ok',
      spotlight: true,
    })
  }

  // Anti-patterns summary
  metrics.push({
    label: '안티패턴',
    value: String(ANTI_PATTERNS.length),
    caption: `${silentFailures.length} silent · ${critHigh.length} crit+high`,
    kind: critHigh.length > 5 ? 'warn' : undefined,
  })

  // Feature coverage
  metrics.push({
    label: '저커버리지 기능',
    value: String(lowCoverageFeatures.length),
    caption: `${FEATURES.length} features × 13 providers`,
    kind: lowCoverageFeatures.length > 5 ? 'warn' : undefined,
  })

  // BFCL top score
  if (bestBfcl) {
    metrics.push({
      label: 'BFCL #1',
      value: bestBfcl.bfclV4,
      caption: bestBfcl.model,
    })
  }

  // Live providers
  metrics.push({
    label: '런타임 프로바이더',
    value: String(liveCount),
    caption: liveCount > 0 ? `${liveCount} active` : 'no live data',
    kind: liveCount === 0 ? 'warn' : undefined,
  })

  // Wiring gap summary
  metrics.push({
    label: '배선 갭',
    value: String(totalGaps),
    caption: `${highGaps.length} high · ${WIRING_GAPS.filter(g => g.impact === 'medium').length} med`,
  })

  return metrics
}

export function CapabilitySummaryStrip(props: CapabilitySummaryProps): VNode {
  const metrics = useMemo(
    () => deriveMetrics(props.liveProviders ?? []),
    [props.liveProviders],
  )

  const cells = metrics.map(m => ({
    label: m.label,
    value: m.value,
    caption: m.caption,
    kind: m.kind,
    spotlight: m.spotlight,
  })) satisfies KpiStripIslandData['cells']

  return html`
    <${KpiStripIsland}
      ariaLabel="Provider capability summary"
      cols=${metrics.length}
      cells=${cells}
    />
  `
}
