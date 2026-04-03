import type { DashboardNamespaceTruthResponse, DashboardShellResponse } from './types'

export type RuntimeCountSource =
  | 'execution'
  | 'namespace-truth'
  | 'shell'
  | 'partial'
  | 'unknown'

export interface RuntimeCounts {
  agents: number
  keepers: number
  tasks: number
  totalRuntimes: number
  source: RuntimeCountSource
}

interface ResolveRuntimeCountsOptions {
  executionLoaded: boolean
  agentsCount: number
  keepersCount: number
  tasksCount?: number
  namespaceTruthCounts?: DashboardNamespaceTruthResponse['namespace']['counts']
  shellCounts?: DashboardShellResponse['counts'] | null
}

function normalizeCount(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : 0
}

function normalizeCounts(
  raw: DashboardNamespaceTruthResponse['namespace']['counts'] | DashboardShellResponse['counts'] | null | undefined,
) {
  if (!raw) return null
  return {
    agents: normalizeCount(raw.agents),
    keepers: normalizeCount(raw.keepers),
    tasks: normalizeCount(raw.tasks),
  }
}

export function resolveRuntimeCounts({
  executionLoaded,
  agentsCount,
  keepersCount,
  tasksCount = 0,
  namespaceTruthCounts,
  shellCounts,
}: ResolveRuntimeCountsOptions): RuntimeCounts {
  const live = {
    agents: normalizeCount(agentsCount),
    keepers: normalizeCount(keepersCount),
    tasks: normalizeCount(tasksCount),
  }
  const namespace = normalizeCounts(namespaceTruthCounts)
  const shell = normalizeCounts(shellCounts)
  const liveTotalRuntimes = live.agents + live.keepers
  const namespaceTotalRuntimes = (namespace?.agents ?? 0) + (namespace?.keepers ?? 0)
  const shellTotalRuntimes = (shell?.agents ?? 0) + (shell?.keepers ?? 0)

  if (executionLoaded && (liveTotalRuntimes > 0 || (namespaceTotalRuntimes === 0 && shellTotalRuntimes === 0))) {
    return {
      ...live,
      totalRuntimes: liveTotalRuntimes,
      source: 'execution',
    }
  }

  if (namespaceTotalRuntimes > 0) {
    return {
      ...namespace!,
      totalRuntimes: namespaceTotalRuntimes,
      source: 'namespace-truth',
    }
  }

  if (shellTotalRuntimes > 0) {
    return {
      ...shell!,
      totalRuntimes: shellTotalRuntimes,
      source: 'shell',
    }
  }

  if (liveTotalRuntimes > 0 || live.tasks > 0) {
    return {
      ...live,
      totalRuntimes: liveTotalRuntimes,
      source: executionLoaded ? 'execution' : 'partial',
    }
  }

  return {
    ...live,
    totalRuntimes: liveTotalRuntimes,
    source: executionLoaded ? 'execution' : 'unknown',
  }
}

export function runtimeCountSourceLabel(source: RuntimeCountSource): string {
  switch (source) {
    case 'execution':
      return 'execution 상세'
    case 'namespace-truth':
      return 'namespace-truth'
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
