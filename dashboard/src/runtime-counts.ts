import type { DashboardNamespaceTruthResponse, DashboardShellResponse } from './types'

type RuntimeCountSource =
  | 'execution'
  | 'project-snapshot'
  | 'shell'
  | 'partial'
  | 'unknown'

interface RuntimeCounts {
  agents: number
  keepers: number
  tasks: number
  totalRuntimes: number
  configuredKeepers: number
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
  const live = {
    agents: normalizeCount(agentsCount),
    keepers: normalizeCount(keepersCount),
    tasks: normalizeCount(tasksCount),
  }
  const namespace = normalizeCounts(namespaceTruthCounts)
  const shell = normalizeCounts(shellCounts)
  const liveTotalRuntimes = live.agents + live.keepers
  const namespaceTotalRuntimes = namespace?.totalRuntimes ?? 0
  const shellTotalRuntimes = shell?.totalRuntimes ?? 0
  const configuredKeepers =
    namespaceTruthConfiguredKeepers != null
      ? normalizeCount(namespaceTruthConfiguredKeepers)
      : shellConfiguredKeepers != null
        ? normalizeCount(shellConfiguredKeepers)
        : live.keepers

  if (executionLoaded && (liveTotalRuntimes > 0 || (namespaceTotalRuntimes === 0 && shellTotalRuntimes === 0))) {
    return {
      ...live,
      totalRuntimes: liveTotalRuntimes,
      configuredKeepers,
      source: 'execution',
    }
  }

  if (liveTotalRuntimes > 0) {
    return {
      ...live,
      totalRuntimes: liveTotalRuntimes,
      configuredKeepers,
      source: 'partial',
    }
  }

  if (namespaceTotalRuntimes > 0) {
    return {
      ...namespace!,
      totalRuntimes: namespaceTotalRuntimes,
      configuredKeepers,
      source: 'project-snapshot',
    }
  }

  if (shellTotalRuntimes > 0) {
    return {
      ...shell!,
      totalRuntimes: shellTotalRuntimes,
      configuredKeepers,
      source: 'shell',
    }
  }

  if (liveTotalRuntimes > 0 || live.tasks > 0) {
    return {
      ...live,
      totalRuntimes: liveTotalRuntimes,
      configuredKeepers,
      source: executionLoaded ? 'execution' : 'partial',
    }
  }

  return {
    ...live,
    totalRuntimes: liveTotalRuntimes,
    configuredKeepers,
    source: executionLoaded ? 'execution' : 'unknown',
  }
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
