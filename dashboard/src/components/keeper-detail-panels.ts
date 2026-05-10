// Keeper detail sub-components — barrel re-exports.
// Components were decomposed into keeper-detail-* flat modules.
// This file remains for backward compatibility.

export {
  autonomyHint,
  ctxColor,
  ctxSegmentLabel,
  ctxSegmentColor,
  filterCtxCompositionEntries,
  formatDuration,
  CTX_CRITICAL_PCT,
  CTX_WARN_PCT,
  CTX_COLOR_CRITICAL,
  CTX_COLOR_WARN,
  CTX_COLOR_OK,
  CTX_SEGMENT_LABELS,
  CTX_SEGMENT_COLORS,
} from './keeper-detail-ctx-utils'

export {
  MutedSpan,
  DetailRow,
  DetailCard,
  OperationalHealth,
  KpiSection,
  KpiGrid,
} from './keeper-detail-kpi'

export { OutcomesLedger } from './keeper-detail-outcomes'

export {
  ContextChart,
  TokenTrendChart,
  MetricsCharts,
} from './keeper-detail-charts'

export {
  PromptTelemetryPanel,
  InferenceTelemetryPanel,
} from './keeper-detail-telemetry'

export { CtxCompositionPanel } from './keeper-detail-ctx-composition'

export { RawDataDebug } from './keeper-detail-debug'

export {
  EquipmentList,
  RelationshipList,
  TraitsList,
} from './keeper-detail-lists'
