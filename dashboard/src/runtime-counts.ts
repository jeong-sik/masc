import type { DashboardNamespaceTruthResponse, DashboardShellResponse } from './types'

export type RuntimeCountSource =
  | 'execution'
  | 'project-snapshot'
  | 'shell'
  | 'partial'
  | 'unknown'

export type ConfiguredCountSource = 'namespace-truth' | 'shell' | 'none'

export interface LiveRuntimeView {
  agents: number
  keepers: number
  pausedKeepers: number
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
  configuredKeepers: number
}

export type CommandTargetKind = 'agent' | 'keeper' | 'session'

interface ResolveRuntimeCountsOptions {
  executionLoaded: boolean
  agentsCount: number
  keepersCount: number
  pausedKeepersCount?: number
  tasksCount?: number
  namespaceTruthCounts?: DashboardNamespaceTruthResponse['root']['counts']
  namespaceTruthConfiguredKeepers?: number
  shellCounts?: DashboardShellResponse['counts'] | null
  shellConfiguredKeepers?: number
}

function normalizeCount(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : 0
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
}: {
  executionLoaded: boolean
  live: LiveRuntimeView
  configured: ConfiguredRuntimeView
}): RuntimeCountSource {
  if (executionLoaded && (live.totalRuntimes > 0 || configured.totalRuntimes === 0)) {
    return 'execution'
  }
  if (live.totalRuntimes > 0) return 'partial'
  if (configured.source === 'namespace-truth') return 'project-snapshot'
  if (configured.source === 'shell') return 'shell'
  return executionLoaded ? 'execution' : 'unknown'
}

export function resolveRuntimeCounts({
  executionLoaded,
  agentsCount,
  keepersCount,
  pausedKeepersCount = 0,
  tasksCount = 0,
  namespaceTruthCounts,
  namespaceTruthConfiguredKeepers,
  shellCounts,
  shellConfiguredKeepers,
}: ResolveRuntimeCountsOptions): RuntimeCounts {
  const liveAgents = normalizeCount(agentsCount)
  const liveKeepers = normalizeCount(keepersCount)
  const livePausedKeepers = normalizeCount(pausedKeepersCount)
  const liveTasks = normalizeCount(tasksCount)
  const live: LiveRuntimeView = {
    agents: liveAgents,
    keepers: liveKeepers,
    pausedKeepers: livePausedKeepers,
    tasks: liveTasks,
    totalRuntimes: liveAgents + liveKeepers,
    available: executionLoaded,
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

  const source = deriveStatusSource({ executionLoaded, live, configured })
  return { live, configured, source }
}

export function runtimeCountSourceLabel(source: RuntimeCountSource): string {
  switch (source) {
    case 'execution':
      return 'execution 상세'
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
    const configured = counts.configured.keepers
    const parts = [`활성 ${running}`]
    if (paused > 0) parts.push(`일시정지 ${paused}`)
    parts.push(`설정 ${configured}`)
    return parts.join(' / ')
  }
  return `활성 ${counts.live.totalRuntimes} / 설정 ${counts.configured.totalRuntimes}`
}

export function keeperDetailRows(counts: Pick<RuntimeCounts, 'live'>): number {
  return counts.live.keepers + counts.live.pausedKeepers
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
  configuredKeepers,
}: KeeperCountBreakdownInput): string {
  const parts = [`키퍼 활성 ${normalizeCount(liveKeepers)}`]
  const paused = normalizeCount(pausedKeepers)
  if (paused > 0) parts.push(`일시정지 ${paused}`)
  parts.push(`설정 ${normalizeCount(configuredKeepers)}`)
  return parts.join(' / ')
}

export function formatKeeperRosterCount(counts: Pick<RuntimeCounts, 'live' | 'configured'>): string {
  return [
    `상세 ${keeperDetailRows(counts)}`,
    formatKeeperCountBreakdown({
      liveKeepers: counts.live.keepers,
      pausedKeepers: counts.live.pausedKeepers,
      configuredKeepers: counts.configured.keepers,
    }).replace(/^키퍼 /, ''),
  ].join(' / ')
}

export function formatRuntimeRosterCount(counts: Pick<RuntimeCounts, 'live' | 'configured'>): string {
  return [
    `상세 ${runtimeDetailRows(counts)}`,
    `활성 ${counts.live.totalRuntimes}`,
    `키퍼 설정 ${counts.configured.keepers}`,
  ].join(' / ')
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
