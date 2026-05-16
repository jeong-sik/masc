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

interface ResolveRuntimeCountsOptions {
  executionLoaded: boolean
  agentsCount: number
  keepersCount: number
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
  namespaceTotalRuntimes,
  namespaceKeepers,
  namespaceConfiguredKeepers,
  shellTotalRuntimes,
  shellConfiguredKeepers,
}: {
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
  if (shellConfiguredKeepers != null || shellTotalRuntimes > 0) {
    return {
      keepers: shellConfiguredKeepers ?? 0,
      totalRuntimes: shellTotalRuntimes,
      source: 'shell',
    }
  }
  if (namespaceTotalRuntimes > 0) {
    return {
      keepers: namespaceKeepers,
      totalRuntimes: namespaceTotalRuntimes,
      source: 'namespace-truth',
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
  tasksCount = 0,
  namespaceTruthCounts,
  namespaceTruthConfiguredKeepers,
  shellCounts,
  shellConfiguredKeepers,
}: ResolveRuntimeCountsOptions): RuntimeCounts {
  const liveAgents = normalizeCount(agentsCount)
  const liveKeepers = normalizeCount(keepersCount)
  const liveTasks = normalizeCount(tasksCount)
  const live: LiveRuntimeView = {
    agents: liveAgents,
    keepers: liveKeepers,
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
  const active = kind === 'keeper' ? counts.live.keepers : counts.live.totalRuntimes
  const configured = kind === 'keeper' ? counts.configured.keepers : counts.configured.totalRuntimes
  return `활성 ${active} / 설정 ${configured}`
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
