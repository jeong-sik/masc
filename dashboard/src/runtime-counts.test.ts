import { describe, expect, it } from 'vitest'
import {
  configuredCountSourceLabel,
  formatActiveOverConfigured,
  resolveRuntimeCounts,
  runtimeCountSourceLabel,
  shouldShowExecutionFallbackState,
} from './runtime-counts'

describe('resolveRuntimeCounts', () => {
  it('exposes namespace-truth as the configured view while execution is still warming', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
      namespaceTruthConfiguredKeepers: 5,
      shellCounts: { agents: 1, keepers: 1, tasks: 4 },
    })).toEqual({
      live: { agents: 0, keepers: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 5, totalRuntimes: 5, source: 'namespace-truth' },
      source: 'project-snapshot',
    })
  })

  it('falls back to shell as the configured view when namespace-truth is unavailable', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
      shellCounts: { agents: 4, keepers: 1, tasks: 9 },
      shellConfiguredKeepers: 3,
    })).toEqual({
      live: { agents: 0, keepers: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 3, totalRuntimes: 5, source: 'shell' },
      source: 'shell',
    })
  })

  it('exposes both live and configured views simultaneously when execution has hydrated', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 2,
      keepersCount: 3,
      tasksCount: 1,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
      namespaceTruthConfiguredKeepers: 5,
    })).toEqual({
      live: { agents: 2, keepers: 3, tasks: 1, totalRuntimes: 5, available: true },
      configured: { keepers: 5, totalRuntimes: 5, source: 'namespace-truth' },
      source: 'execution',
    })
  })

  it('keeps live and configured separate during warmup with partial runtime rows', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 12,
      namespaceTruthCounts: { agents: 0, keepers: 14, tasks: 103 },
      namespaceTruthConfiguredKeepers: 14,
      shellCounts: { agents: 13, keepers: 12, tasks: 103, total_runtimes: 25 },
      shellConfiguredKeepers: 14,
    })).toEqual({
      live: { agents: 0, keepers: 12, tasks: 0, totalRuntimes: 12, available: false },
      configured: { keepers: 14, totalRuntimes: 14, source: 'namespace-truth' },
      source: 'partial',
    })
  })

  it('preserves configured view when execution finished but live rows are empty', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 0,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
      namespaceTruthConfiguredKeepers: 4,
    })).toEqual({
      live: { agents: 0, keepers: 0, tasks: 0, totalRuntimes: 0, available: true },
      configured: { keepers: 4, totalRuntimes: 5, source: 'namespace-truth' },
      source: 'project-snapshot',
    })
  })

  it('reports both 2 live and 16 configured keepers in the fluctuation scenario without picking a winner', () => {
    // Real-world reproduction: composite API returns 2 active fiber keepers
    // while .masc/keepers/ holds 16 persona registrations. Both must surface
    // simultaneously so the UI can render "활성 2 / 설정 16" instead of swapping.
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 2,
      namespaceTruthCounts: { agents: 0, keepers: 16, tasks: 0 },
      namespaceTruthConfiguredKeepers: 16,
    })).toEqual({
      live: { agents: 0, keepers: 2, tasks: 0, totalRuntimes: 2, available: true },
      configured: { keepers: 16, totalRuntimes: 16, source: 'namespace-truth' },
      source: 'execution',
    })
  })

  it('returns configured.source=none and source=unknown when every source is missing', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
    })).toEqual({
      live: { agents: 0, keepers: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 0, totalRuntimes: 0, source: 'none' },
      source: 'unknown',
    })
  })

  it('marks live.available=true even when execution returned zero rows after loading', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 0,
    })).toMatchObject({
      live: { available: true, totalRuntimes: 0 },
      configured: { source: 'none' },
      source: 'execution',
    })
  })
})

describe('runtimeCountSourceLabel', () => {
  it('maps count source ids to user-facing labels', () => {
    expect(runtimeCountSourceLabel('execution')).toBe('execution 상세')
    expect(runtimeCountSourceLabel('project-snapshot')).toBe('project snapshot')
    expect(runtimeCountSourceLabel('shell')).toBe('shell')
    expect(runtimeCountSourceLabel('partial')).toBe('부분 hydrate')
    expect(runtimeCountSourceLabel('unknown')).toBe('미수집')
  })
})

describe('configuredCountSourceLabel', () => {
  it('maps configured count source ids to user-facing labels', () => {
    expect(configuredCountSourceLabel('namespace-truth')).toBe('project snapshot')
    expect(configuredCountSourceLabel('shell')).toBe('shell')
    expect(configuredCountSourceLabel('none')).toBe('미수집')
  })
})

describe('formatActiveOverConfigured', () => {
  it('formats keeper counts as "활성 N / 설정 M"', () => {
    const counts = {
      live: { agents: 0, keepers: 2, tasks: 0, totalRuntimes: 2, available: true },
      configured: { keepers: 16, totalRuntimes: 16, source: 'namespace-truth' as const },
    }
    expect(formatActiveOverConfigured(counts, 'keeper')).toBe('활성 2 / 설정 16')
  })

  it('formats runtime totals as "활성 N / 설정 M"', () => {
    const counts = {
      live: { agents: 3, keepers: 2, tasks: 0, totalRuntimes: 5, available: true },
      configured: { keepers: 16, totalRuntimes: 20, source: 'namespace-truth' as const },
    }
    expect(formatActiveOverConfigured(counts, 'runtime')).toBe('활성 5 / 설정 20')
  })

  it('defaults kind to "keeper" when omitted', () => {
    const counts = {
      live: { agents: 0, keepers: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 0, totalRuntimes: 0, source: 'none' as const },
    }
    expect(formatActiveOverConfigured(counts)).toBe('활성 0 / 설정 0')
  })
})

describe('shouldShowExecutionFallbackState', () => {
  it('shows a fallback state while expected runtimes are still missing', () => {
    expect(shouldShowExecutionFallbackState({
      executionLoaded: false,
      executionLoading: true,
      executionError: null,
      loadedCount: 0,
      expectedCount: 5,
    })).toBe(true)
  })

  it('shows a fallback state on execution error when truth says runtimes should exist', () => {
    expect(shouldShowExecutionFallbackState({
      executionLoaded: false,
      executionLoading: false,
      executionError: 'timeout',
      loadedCount: 0,
      expectedCount: 5,
    })).toBe(true)
  })

  it('hides the fallback state once loaded counts match expected truth', () => {
    expect(shouldShowExecutionFallbackState({
      executionLoaded: true,
      executionLoading: false,
      executionError: null,
      loadedCount: 5,
      expectedCount: 5,
    })).toBe(false)
  })
})
