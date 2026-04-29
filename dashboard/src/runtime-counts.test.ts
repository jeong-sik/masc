import { describe, expect, it } from 'vitest'
import {
  resolveRuntimeCounts,
  runtimeCountSourceLabel,
  shouldShowExecutionFallbackState,
} from './runtime-counts'

describe('resolveRuntimeCounts', () => {
  it('uses project-snapshot counts while execution is still warming', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
      namespaceTruthConfiguredKeepers: 5,
      shellCounts: { agents: 1, keepers: 1, tasks: 4 },
    })).toEqual({
      agents: 2,
      keepers: 3,
      tasks: 12,
      totalRuntimes: 5,
      configuredKeepers: 5,
      source: 'project-snapshot',
    })
  })

  it('falls back to shell counts when project-snapshot is unavailable', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
      shellCounts: { agents: 4, keepers: 1, tasks: 9 },
      shellConfiguredKeepers: 3,
    })).toEqual({
      agents: 4,
      keepers: 1,
      tasks: 9,
      totalRuntimes: 5,
      configuredKeepers: 3,
      source: 'shell',
    })
  })

  it('prefers live execution counts once execution has hydrated', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 2,
      keepersCount: 3,
      tasksCount: 1,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
      namespaceTruthConfiguredKeepers: 5,
    })).toEqual({
      agents: 2,
      keepers: 3,
      tasks: 1,
      totalRuntimes: 5,
      configuredKeepers: 5,
      source: 'execution',
    })
  })

  it('prefers visible runtime rows over configured fallback counts while execution is still warming', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 12,
      namespaceTruthCounts: { agents: 0, keepers: 14, tasks: 103 },
      namespaceTruthConfiguredKeepers: 14,
      shellCounts: { agents: 13, keepers: 12, tasks: 103, total_runtimes: 25 },
      shellConfiguredKeepers: 14,
    })).toEqual({
      agents: 0,
      keepers: 12,
      tasks: 0,
      totalRuntimes: 12,
      configuredKeepers: 14,
      source: 'partial',
    })
  })

  it('keeps fallback truth when execution says loaded but runtime rows are still empty', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 0,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
      namespaceTruthConfiguredKeepers: 4,
    })).toEqual({
      agents: 2,
      keepers: 3,
      tasks: 12,
      totalRuntimes: 5,
      configuredKeepers: 4,
      source: 'project-snapshot',
    })
  })
})

describe('runtimeCountSourceLabel', () => {
  it('maps count source ids to user-facing labels', () => {
    expect(runtimeCountSourceLabel('execution')).toBe('execution 상세')
    expect(runtimeCountSourceLabel('project-snapshot')).toBe('project snapshot')
    expect(runtimeCountSourceLabel('shell')).toBe('shell')
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
