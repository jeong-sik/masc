// MASC Dashboard — cost dashboard shared state
//
// Module-level Preact signals consumed by cost-dashboard.ts and (in the
// future) other panels that surface the same telemetry. Centralizing the
// store here means the host components stop owning the SSOT directly and
// can be swapped (e.g. extracting Advanced telemetry into a dedicated
// surface) without breaking the data flow.
//
// Mount safety note: these signals are singletons; if two host components
// mount simultaneously they share state. The current cost-dashboard host
// guards against that by rendering exactly one view at a time, but any
// future re-host MUST preserve mutual exclusion or migrate to a factory
// pattern (per-mount instances).

import { signal } from '@preact/signals'
import type {
  DashboardRuntimeModelMetric,
  KeeperCostMetric,
  LatencyBucket,
  HeuristicEvent,
  HeuristicCoverage,
  StressEvent,
  AgentStressRow,
  AuditLedgerResponse,
  KeeperDecisionsResponse,
  DashboardFeedMetadata,
} from '../../api/dashboard'
import type { ViewMode } from './cost-types'

export type ModelLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: DashboardRuntimeModelMetric[]; latencyBuckets: LatencyBucket[]; windowMinutes: number }
  | { status: 'error'; message: string }

export type KeeperLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: KeeperCostMetric[]; windowMinutes: number }
  | { status: 'error'; message: string }

export type HeuristicLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: HeuristicEvent[]; limit: number; meta: DashboardFeedMetadata }
  | { status: 'error'; message: string }

export type StressLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; events: StressEvent[]; board: AgentStressRow[]; limit: number; meta: DashboardFeedMetadata }
  | { status: 'error'; message: string }

export type CoverageLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: HeuristicCoverage }
  | { status: 'error'; message: string }

export type AuditLedgerLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: AuditLedgerResponse }
  | { status: 'error'; message: string }

export type KeeperDecisionsLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: KeeperDecisionsResponse }
  | { status: 'error'; message: string }

export const viewMode = signal<ViewMode>('model')
export const modelState = signal<ModelLoadState>({ status: 'idle' })
export const keeperState = signal<KeeperLoadState>({ status: 'idle' })
export const heuristicState = signal<HeuristicLoadState>({ status: 'idle' })
export const stressState = signal<StressLoadState>({ status: 'idle' })
export const coverageState = signal<CoverageLoadState>({ status: 'idle' })
export const auditLedgerState = signal<AuditLedgerLoadState>({ status: 'idle' })
export const keeperDecisionsState = signal<KeeperDecisionsLoadState>({ status: 'idle' })
export const windowMinutes = signal<number>(60)
