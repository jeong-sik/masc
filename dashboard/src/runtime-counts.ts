import type { DashboardFleetSafetyHealth, DashboardNamespaceTruthResponse, DashboardShellResponse } from './types'

export type RuntimeCountSource =
  | 'execution'
  | 'runtime-health'
  | 'project-snapshot'
  | 'shell'
  | 'partial'
  | 'unknown'

export type ConfiguredCountSource = 'namespace-truth' | 'shell' | 'none'

export interface LiveRuntimeView {
  agents: number
  keepers: number
  pausedKeepers: number
  // Transient keeper count — RFC-0295. Always present (even when the
  // underlying source can't enumerate it) so downstream consumers can
  // reconcile `keepers + pausedKeepers + transientKeepers + offlineKeepers`
  // against `keeperRows` without guessing.
  transientKeepers: number
  offlineKeepers: number
  keeperRows: number
  tasks: number
  totalRuntimes: number
  available: boolean
}

export interface ConfiguredRuntimeView {
  keepers: number
  totalRuntimes: number
  source: ConfiguredCountSource
}

export interface RuntimeCounts {
  live: LiveRuntimeView
  configured: ConfiguredRuntimeView
  source: RuntimeCountSource
}

export interface KeeperCountBreakdownInput {
  liveKeepers: number
  pausedKeepers?: number
  transientKeepers?: number
  offlineKeepers?: number
  configuredKeepers: number
}

export type CommandTargetKind = 'agent' | 'keeper' | 'session'

interface ResolveRuntimeCountsOptions {
  executionLoaded: boolean
  agentsCount: number
  keepersCount: number
  pausedKeepersCount?: number
  transientKeepersCount?: number
  offlineKeepersCount?: number
  keeperRowsCount?: number
  tasksCount?: number
  namespaceTruthCounts?: DashboardNamespaceTruthResponse['root']['counts']
  namespaceTruthConfiguredKeepers?: number
  shellCounts?: DashboardShellResponse['counts'] | null
  shellConfiguredKeepers?: number
  runtimeFleetSafety?: DashboardFleetSafetyHealth | null
  runtimeHealthGeneratedAt?: string | null
  nowMs?: number
}

function finiteCount(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null
  return Math.max(0, Math.floor(value))
}

function normalizeCount(value: unknown): number {
  return finiteCount(value) ?? 0
}

function normalizeRuntimeToken(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

export interface KeeperRuntimeCountRow {
  status?: string | null
  phase?: string | null
  pipeline_stage?: string | null
  paused?: boolean | null
  keepalive_running?: boolean | null
}

const TERMINAL_KEEPER_RUNTIME_TOKENS = new Set(['paused', 'stopped', 'dead', 'crashed'])
const OFFLINE_KEEPER_RUNTIME_TOKENS = new Set(['offline', 'inactive'])
const RUNNING_KEEPER_RUNTIME_TOKENS = new Set(['active', 'busy', 'listening', 'idle', 'running'])

export function keeperRowLooksRunning(row: KeeperRuntimeCountRow | null | undefined): boolean {
  if (!row || row.paused === true) return false

  const status = normalizeRuntimeToken(row.status)
  const phase = normalizeRuntimeToken(row.phase)
  const stage = normalizeRuntimeToken(row.pipeline_stage)
  if (
    TERMINAL_KEEPER_RUNTIME_TOKENS.has(status)
    || TERMINAL_KEEPER_RUNTIME_TOKENS.has(phase)
    || TERMINAL_KEEPER_RUNTIME_TOKENS.has(stage)
  ) return false

  if (row.keepalive_running === true) return true
  if (row.keepalive_running === false) return false

  if (
    OFFLINE_KEEPER_RUNTIME_TOKENS.has(status)
    || OFFLINE_KEEPER_RUNTIME_TOKENS.has(phase)
    || OFFLINE_KEEPER_RUNTIME_TOKENS.has(stage)
  ) return false

  return (
    RUNNING_KEEPER_RUNTIME_TOKENS.has(status)
    || RUNNING_KEEPER_RUNTIME_TOKENS.has(phase)
    || RUNNING_KEEPER_RUNTIME_TOKENS.has(stage)
  )
}

export interface RuntimeFleetSafetyCounts {
  runningKeepers: number
  pausedKeepers: number
  hasRunningKeepers: boolean
  hasPausedKeepers: boolean
}

export const RUNTIME_HEALTH_FRESH_MS = 120_000

function firstFiniteCount(...values: unknown[]): number | null {
  for (const value of values) {
    const count = finiteCount(value)
    if (count !== null) return count
  }
  return null
}

export function resolveRuntimeFleetSafetyCounts(
  fleetSafety: DashboardFleetSafetyHealth | null | undefined,
): RuntimeFleetSafetyCounts | null {
  if (!fleetSafety) return null
  const fleet = fleetSafety.keeper_fleet_safety
  const runningKeepers = firstFiniteCount(fleet?.running_keeper_fiber_count)
  const pausedKeepers = firstFiniteCount(
    fleetSafety.paused_keepers_health?.count,
    fleet?.paused_keeper_count,
    fleetSafety.paused_keepers,
  )
  if (runningKeepers === null && pausedKeepers === null) return null
  return {
    runningKeepers: runningKeepers ?? 0,
    pausedKeepers: pausedKeepers ?? 0,
    hasRunningKeepers: runningKeepers !== null,
    hasPausedKeepers: pausedKeepers !== null,
  }
}

export function runtimeHealthIsFresh(
  generatedAt: string | null | undefined,
  nowMs = Date.now(),
): boolean {
  if (!generatedAt) return true
  const timestampMs = Date.parse(generatedAt)
  if (!Number.isFinite(timestampMs)) return false
  return Math.max(0, nowMs - timestampMs) <= RUNTIME_HEALTH_FRESH_MS
}

function normalizeCounts(
  raw: DashboardNamespaceTruthResponse['root']['counts'] | DashboardShellResponse['counts'] | null | undefined,
) {
  if (!raw) return null
  return {
    agents: normalizeCount(raw.agents),
    keepers: normalizeCount(raw.keepers),
    tasks: normalizeCount(raw.tasks),
    totalRuntimes:
      typeof raw.total_runtimes === 'number' && Number.isFinite(raw.total_runtimes)
        ? Math.max(0, Math.floor(raw.total_runtimes))
        : normalizeCount(raw.agents) + normalizeCount(raw.keepers),
  }
}

function resolveConfiguredView({
  namespaceCountsAvailable,
  namespaceTotalRuntimes,
  namespaceKeepers,
  namespaceConfiguredKeepers,
  shellTotalRuntimes,
  shellConfiguredKeepers,
}: {
  namespaceCountsAvailable: boolean
  namespaceTotalRuntimes: number
  namespaceKeepers: number
  namespaceConfiguredKeepers: number | null
  shellTotalRuntimes: number
  shellConfiguredKeepers: number | null
}): ConfiguredRuntimeView {
  if (namespaceConfiguredKeepers != null) {
    return {
      keepers: namespaceConfiguredKeepers,
      totalRuntimes: namespaceTotalRuntimes,
      source: 'namespace-truth',
    }
  }
  if (namespaceCountsAvailable) {
    return {
      keepers: namespaceKeepers,
      totalRuntimes: namespaceTotalRuntimes,
      source: 'namespace-truth',
    }
  }
  if (shellConfiguredKeepers != null || shellTotalRuntimes > 0) {
    return {
      keepers: shellConfiguredKeepers ?? 0,
      totalRuntimes: shellTotalRuntimes,
      source: 'shell',
    }
  }
  return { keepers: 0, totalRuntimes: 0, source: 'none' }
}

function deriveStatusSource({
  executionLoaded,
  live,
  configured,
  runtimeHealthAvailable,
}: {
  executionLoaded: boolean
  live: LiveRuntimeView
  configured: ConfiguredRuntimeView
  runtimeHealthAvailable: boolean
}): RuntimeCountSource {
  const liveDetailRows = live.agents + live.keeperRows
  if (runtimeHealthAvailable) return 'runtime-health'
  if (executionLoaded && (liveDetailRows > 0 || configured.totalRuntimes === 0)) {
    return 'execution'
  }
  if (liveDetailRows > 0) return 'partial'
  if (configured.source === 'namespace-truth') return 'project-snapshot'
  if (configured.source === 'shell') return 'shell'
  return executionLoaded ? 'execution' : 'unknown'
}

export function resolveRuntimeCounts({
  executionLoaded,
  agentsCount,
  keepersCount,
  pausedKeepersCount = 0,
  transientKeepersCount = 0,
  offlineKeepersCount,
  keeperRowsCount,
  tasksCount = 0,
  namespaceTruthCounts,
  namespaceTruthConfiguredKeepers,
  shellCounts,
  shellConfiguredKeepers,
  runtimeFleetSafety,
  runtimeHealthGeneratedAt,
  nowMs,
}: ResolveRuntimeCountsOptions): RuntimeCounts {
  const runtimeHealthCounts = runtimeHealthIsFresh(runtimeHealthGeneratedAt, nowMs)
    ? resolveRuntimeFleetSafetyCounts(runtimeFleetSafety)
    : null
  const liveAgents = normalizeCount(agentsCount)
  const runtimeHealthAvailable = runtimeHealthCounts !== null
  const liveKeepers = runtimeHealthAvailable
    ? runtimeHealthCounts.runningKeepers
    : normalizeCount(keepersCount)
  const livePausedKeepers = runtimeHealthAvailable
    ? runtimeHealthCounts.pausedKeepers
    : normalizeCount(pausedKeepersCount)
  // Runtime-health fleet_safety is authoritative for running/paused fibers,
  // but it does not enumerate RFC-0295 transient detail rows. Preserve the
  // row-derived transient count so the live view remains reconcilable without
  // synthesizing offline rows from stale execution snapshots.
  const liveTransientKeepers = normalizeCount(transientKeepersCount)
  const liveOfflineKeepers = runtimeHealthAvailable ? 0 : normalizeCount(offlineKeepersCount)
  const liveKeeperRows = runtimeHealthAvailable
    ? liveKeepers + livePausedKeepers + liveTransientKeepers
    : Math.max(
        normalizeCount(keeperRowsCount),
        liveKeepers + livePausedKeepers + liveTransientKeepers + liveOfflineKeepers,
      )
  const liveTasks = normalizeCount(tasksCount)
  const live: LiveRuntimeView = {
    agents: liveAgents,
    keepers: liveKeepers,
    pausedKeepers: livePausedKeepers,
    transientKeepers: liveTransientKeepers,
    offlineKeepers: runtimeHealthAvailable
      ? 0
      : Math.max(0, liveKeeperRows - liveKeepers - livePausedKeepers - liveTransientKeepers),
    keeperRows: liveKeeperRows,
    tasks: liveTasks,
    totalRuntimes: liveAgents + liveKeepers,
    available: executionLoaded || runtimeHealthAvailable,
  }

  const namespace = normalizeCounts(namespaceTruthCounts)
  const shell = normalizeCounts(shellCounts)
  const namespaceConfiguredKeepers =
    namespaceTruthConfiguredKeepers != null ? normalizeCount(namespaceTruthConfiguredKeepers) : null
  const shellConfiguredKeeperCount =
    shellConfiguredKeepers != null ? normalizeCount(shellConfiguredKeepers) : null

  const configured = resolveConfiguredView({
    namespaceCountsAvailable: namespace !== null,
    namespaceTotalRuntimes: namespace?.totalRuntimes ?? 0,
    namespaceKeepers: namespace?.keepers ?? 0,
    namespaceConfiguredKeepers,
    shellTotalRuntimes: shell?.totalRuntimes ?? 0,
    shellConfiguredKeepers: shellConfiguredKeeperCount,
  })

  const source = deriveStatusSource({
    executionLoaded,
    live,
    configured,
    runtimeHealthAvailable,
  })
  return { live, configured, source }
}

export function runtimeCountSourceLabel(source: RuntimeCountSource): string {
  switch (source) {
    case 'execution':
      return 'execution 상세'
    case 'runtime-health':
      return 'runtime health'
    case 'project-snapshot':
      return 'project snapshot'
    case 'shell':
      return 'shell'
    case 'partial':
      return '부분 hydrate'
    default:
      return '미수집'
  }
}

export function configuredCountSourceLabel(source: ConfiguredCountSource): string {
  switch (source) {
    case 'namespace-truth':
      return 'project snapshot'
    case 'shell':
      return 'shell'
    case 'none':
      return '미수집'
  }
}

export function formatActiveOverConfigured(
  counts: Pick<RuntimeCounts, 'live' | 'configured'>,
  kind: 'keeper' | 'runtime' = 'keeper',
): string {
  if (kind === 'keeper') {
    const running = counts.live.keepers
    const paused = counts.live.pausedKeepers
    const transient = counts.live.transientKeepers
    const offline = counts.live.offlineKeepers
    const configured = counts.configured.keepers
    const parts = [`keeper 실행 fiber ${running}`]
    if (paused > 0) parts.push(`일시정지 keeper ${paused}`)
    if (transient > 0) parts.push(`전이 keeper ${transient}`)
    if (offline > 0) parts.push(`오프라인 keeper ${offline}`)
    parts.push(`configured keeper ${configured}`)
    return parts.join(' / ')
  }
  return [
    `keeper 실행 fiber ${counts.live.keepers}`,
    `workspace agents ${counts.live.agents}`,
    `configured runtimes ${counts.configured.totalRuntimes}`,
  ].join(' / ')
}

export function keeperDetailRows(counts: Pick<RuntimeCounts, 'live'>): number {
  return counts.live.keeperRows
}

export function runtimeDetailRows(counts: Pick<RuntimeCounts, 'live'>): number {
  return counts.live.agents + keeperDetailRows(counts)
}

export function expectedKeeperDetailRows(counts: Pick<RuntimeCounts, 'live' | 'configured'>): number {
  return Math.max(keeperDetailRows(counts), counts.configured.keepers)
}

export function expectedRuntimeDetailRows(counts: Pick<RuntimeCounts, 'live' | 'configured'>): number {
  return counts.live.agents + expectedKeeperDetailRows(counts)
}

export function formatKeeperCountBreakdown({
  liveKeepers,
  pausedKeepers = 0,
  transientKeepers = 0,
  offlineKeepers = 0,
  configuredKeepers,
}: KeeperCountBreakdownInput): string {
  const parts = [`keeper 실행 fiber ${normalizeCount(liveKeepers)}`]
  const paused = normalizeCount(pausedKeepers)
  const transient = normalizeCount(transientKeepers)
  const offline = normalizeCount(offlineKeepers)
  if (paused > 0) parts.push(`일시정지 keeper ${paused}`)
  if (transient > 0) parts.push(`전이 keeper ${transient}`)
  if (offline > 0) parts.push(`오프라인 keeper ${offline}`)
  parts.push(`configured keeper ${normalizeCount(configuredKeepers)}`)
  return parts.join(' / ')
}

export function formatKeeperRosterCount(counts: Pick<RuntimeCounts, 'live' | 'configured'>): string {
  return [
    `keeper 행 ${keeperDetailRows(counts)}`,
    formatKeeperCountBreakdown({
      liveKeepers: counts.live.keepers,
      pausedKeepers: counts.live.pausedKeepers,
      transientKeepers: counts.live.transientKeepers,
      offlineKeepers: counts.live.offlineKeepers,
      configuredKeepers: counts.configured.keepers,
    }),
  ].join(' / ')
}

export function formatRuntimeRosterCount(counts: Pick<RuntimeCounts, 'live' | 'configured'>): string {
  const parts = [
    `runtime 행 ${runtimeDetailRows(counts)}`,
    `keeper 실행 fiber ${counts.live.keepers}`,
    `workspace agents ${counts.live.agents}`,
  ]
  if (counts.live.pausedKeepers > 0) parts.push(`일시정지 keeper ${counts.live.pausedKeepers}`)
  if (counts.live.transientKeepers > 0) parts.push(`전이 keeper ${counts.live.transientKeepers}`)
  if (counts.live.offlineKeepers > 0) parts.push(`오프라인 keeper ${counts.live.offlineKeepers}`)
  parts.push(`configured keeper ${counts.configured.keepers}`)
  return parts.join(' / ')
}

export function formatCommandTargetSection(kind: CommandTargetKind, count: number): string {
  const normalized = normalizeCount(count)
  switch (kind) {
    case 'agent':
      return `Mission agent targets (${normalized})`
    case 'keeper':
      return `Mission keeper targets (${normalized})`
    case 'session':
      return `Mission session targets (${normalized})`
  }
}

export function formatCommandTargetSummary({
  agents,
  keepers,
  sessions,
}: {
  agents: number
  keepers: number
  sessions: number
}): string {
  return [
    `명령 대상 에이전트 ${normalizeCount(agents)}`,
    `키퍼 ${normalizeCount(keepers)}`,
    `세션 ${normalizeCount(sessions)}`,
  ].join(' / ')
}

interface ExecutionFallbackStateOptions {
  executionLoaded: boolean
  executionLoading: boolean
  executionError: string | null
  loadedCount: number
  expectedCount: number
}

export function shouldShowExecutionFallbackState({
  executionLoaded,
  executionLoading,
  executionError,
  loadedCount,
  expectedCount,
}: ExecutionFallbackStateOptions): boolean {
  if (expectedCount <= 0) return false
  if (executionError) return true
  if (loadedCount >= expectedCount && executionLoaded) return false
  return executionLoading || !executionLoaded || loadedCount < expectedCount
}
