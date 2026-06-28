import { describe, expect, it } from 'vitest'
import {
  configuredCountSourceLabel,
  formatActiveOverConfigured,
  formatCommandTargetSection,
  formatCommandTargetSummary,
  expectedKeeperDetailRows,
  expectedRuntimeDetailRows,
  formatKeeperCountBreakdown,
  formatKeeperRosterCount,
  formatRuntimeRosterCount,
  keeperRowLooksRunning,
  keeperDetailRows,
  runtimeHealthIsFresh,
  resolveRuntimeFleetSafetyCounts,
  resolveRuntimeCounts,
  runtimeDetailRows,
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
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: false },
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
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 3, totalRuntimes: 5, source: 'shell' },
      source: 'shell',
    })
  })

  it('keeps namespace-truth as configured authority when shell counts disagree', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
      shellCounts: { agents: 6, keepers: 1, tasks: 9, total_runtimes: 8 },
      shellConfiguredKeepers: 7,
    })).toEqual({
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 3, totalRuntimes: 5, source: 'namespace-truth' },
      source: 'project-snapshot',
    })
  })

  it('preserves namespace snapshot totals when configured keepers are omitted', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
      namespaceTruthCounts: { agents: 2, keepers: 3, tasks: 12 },
    })).toEqual({
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 3, totalRuntimes: 5, source: 'namespace-truth' },
      source: 'project-snapshot',
    })
  })

  it('keeps namespace zero counts authoritative over stale shell counts', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
      namespaceTruthCounts: { agents: 0, keepers: 0, tasks: 0, total_runtimes: 0 },
      shellCounts: { agents: 3, keepers: 2, tasks: 9, total_runtimes: 5 },
      shellConfiguredKeepers: 2,
    })).toEqual({
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 0, totalRuntimes: 0, source: 'namespace-truth' },
      source: 'project-snapshot',
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
      live: { agents: 2, keepers: 3, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 3, tasks: 1, totalRuntimes: 5, available: true },
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
      live: { agents: 0, keepers: 12, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 12, tasks: 0, totalRuntimes: 12, available: false },
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
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: true },
      configured: { keepers: 4, totalRuntimes: 5, source: 'namespace-truth' },
      source: 'project-snapshot',
    })
  })

  it('reports both 2 live and 16 configured keepers in the fluctuation scenario without picking a winner', () => {
    // Real-world reproduction: composite API returns 2 running fiber keepers
    // while .masc/keepers/ holds 16 persona registrations. Both must surface
    // simultaneously so the UI can render "keeper 실행 fiber 2 / configured keeper 16" instead of swapping.
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 2,
      namespaceTruthCounts: { agents: 0, keepers: 16, tasks: 0 },
      namespaceTruthConfiguredKeepers: 16,
    })).toEqual({
      live: { agents: 0, keepers: 2, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 2, tasks: 0, totalRuntimes: 2, available: true },
      configured: { keepers: 16, totalRuntimes: 16, source: 'namespace-truth' },
      source: 'execution',
    })
  })

  it('treats paused or offline detail rows as execution evidence even when no keeper is running', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 0,
      pausedKeepersCount: 1,
      offlineKeepersCount: 2,
      keeperRowsCount: 3,
      namespaceTruthCounts: { agents: 0, keepers: 3, tasks: 0 },
      namespaceTruthConfiguredKeepers: 3,
    })).toEqual({
      live: { agents: 0, keepers: 0, pausedKeepers: 1, offlineKeepers: 2, transientKeepers: 0, keeperRows: 3, tasks: 0, totalRuntimes: 0, available: true },
      configured: { keepers: 3, totalRuntimes: 3, source: 'namespace-truth' },
      source: 'execution',
    })
  })

  it('subtracts transient detail rows from offline keeper math', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 1,
      pausedKeepersCount: 1,
      transientKeepersCount: 2,
      offlineKeepersCount: 0,
      keeperRowsCount: 4,
      namespaceTruthCounts: { agents: 0, keepers: 4, tasks: 0 },
      namespaceTruthConfiguredKeepers: 4,
    })).toEqual({
      live: { agents: 0, keepers: 1, pausedKeepers: 1, offlineKeepers: 0, transientKeepers: 2, keeperRows: 4, tasks: 0, totalRuntimes: 1, available: true },
      configured: { keepers: 4, totalRuntimes: 4, source: 'namespace-truth' },
      source: 'execution',
    })
  })

  it('returns configured.source=none and source=unknown when every source is missing', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 0,
    })).toEqual({
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: false },
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

  it('uses structured runtime health as the live keeper count source', () => {
    const runtimeFleetSafety = {
      keeper_fibers: 9,
      paused_keepers: 2,
      paused_keepers_health: { count: 3 },
      keeper_fleet_safety: {
        running_keeper_fiber_count: 0,
        paused_keeper_count: 4,
      },
    } as any

    expect(resolveRuntimeFleetSafetyCounts(runtimeFleetSafety)).toEqual({
      runningKeepers: 0,
      pausedKeepers: 3,
      hasRunningKeepers: true,
      hasPausedKeepers: true,
    })

    expect(resolveRuntimeCounts({
      executionLoaded: false,
      agentsCount: 0,
      keepersCount: 9,
      pausedKeepersCount: 0,
      shellCounts: { agents: 0, keepers: 9, tasks: 0, total_runtimes: 13 },
      shellConfiguredKeepers: 13,
      runtimeFleetSafety,
    })).toEqual({
      live: { agents: 0, keepers: 0, pausedKeepers: 3, offlineKeepers: 0, transientKeepers: 0, keeperRows: 3, tasks: 0, totalRuntimes: 0, available: true },
      configured: { keepers: 13, totalRuntimes: 13, source: 'shell' },
      source: 'runtime-health',
    })
  })

  it('does not fall back to keeper_fibers when running_keeper_fiber_count is absent', () => {
    const runtimeFleetSafety = {
      keeper_fibers: 9,
      keeper_fleet_safety: {},
    } as any

    expect(resolveRuntimeFleetSafetyCounts(runtimeFleetSafety)).toBeNull()
  })

  it('does not derive offline keepers from execution rows when runtime health is authoritative', () => {
    const runtimeFleetSafety = {
      keeper_fleet_safety: {
        running_keeper_fiber_count: 2,
        paused_keeper_count: 1,
      },
    } as any

    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 2,
      pausedKeepersCount: 1,
      transientKeepersCount: 2,
      offlineKeepersCount: 5,
      keeperRowsCount: 8,
      namespaceTruthCounts: { agents: 0, keepers: 8, tasks: 0 },
      namespaceTruthConfiguredKeepers: 8,
      runtimeFleetSafety,
    })).toEqual({
      live: { agents: 0, keepers: 2, pausedKeepers: 1, offlineKeepers: 0, transientKeepers: 2, keeperRows: 5, tasks: 0, totalRuntimes: 2, available: true },
      configured: { keepers: 8, totalRuntimes: 8, source: 'namespace-truth' },
      source: 'runtime-health',
    })
  })

  it('does not treat total keeper_fibers as the running runtime count', () => {
    const runtimeFleetSafety = {
      keeper_fibers: 9,
      paused_keepers: 2,
      paused_keepers_health: null,
      keeper_fleet_safety: {},
    } as any

    expect(resolveRuntimeFleetSafetyCounts(runtimeFleetSafety)).toEqual({
      runningKeepers: 0,
      pausedKeepers: 2,
      hasRunningKeepers: false,
      hasPausedKeepers: true,
    })

    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 9,
      pausedKeepersCount: 0,
      offlineKeepersCount: 6,
      keeperRowsCount: 9,
      shellCounts: { agents: 0, keepers: 9, tasks: 0, total_runtimes: 9 },
      shellConfiguredKeepers: 13,
      runtimeFleetSafety,
    })).toEqual({
      live: { agents: 0, keepers: 0, pausedKeepers: 2, offlineKeepers: 0, transientKeepers: 0, keeperRows: 2, tasks: 0, totalRuntimes: 0, available: true },
      configured: { keepers: 13, totalRuntimes: 9, source: 'shell' },
      source: 'runtime-health',
    })
  })

  it('does not synthesize runtime-health offline counts from execution rows', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 9,
      pausedKeepersCount: 1,
      offlineKeepersCount: 6,
      keeperRowsCount: 9,
      namespaceTruthCounts: { agents: 0, keepers: 13, tasks: 0, total_runtimes: 13 },
      runtimeFleetSafety: {
        keeper_fibers: 9,
        paused_keepers: 1,
        paused_keepers_health: { count: 1 },
        keeper_fleet_safety: {
          running_keeper_fiber_count: 2,
          paused_keeper_count: 1,
        },
      } as any,
    })).toEqual({
      live: { agents: 0, keepers: 2, pausedKeepers: 1, offlineKeepers: 0, transientKeepers: 0, keeperRows: 3, tasks: 0, totalRuntimes: 2, available: true },
      configured: { keepers: 13, totalRuntimes: 13, source: 'namespace-truth' },
      source: 'runtime-health',
    })
  })

  it('ignores stale runtime health and falls back to execution row counts', () => {
    expect(resolveRuntimeCounts({
      executionLoaded: true,
      agentsCount: 0,
      keepersCount: 4,
      pausedKeepersCount: 1,
      offlineKeepersCount: 2,
      keeperRowsCount: 7,
      runtimeHealthGeneratedAt: '2026-06-25T12:00:00Z',
      nowMs: Date.parse('2026-06-25T12:02:01Z'),
      runtimeFleetSafety: {
        keeper_fibers: 9,
        paused_keepers: 3,
        paused_keepers_health: { count: 3 },
        keeper_fleet_safety: {
          running_keeper_fiber_count: 0,
          paused_keeper_count: 3,
        },
      } as any,
    })).toEqual({
      live: { agents: 0, keepers: 4, pausedKeepers: 1, offlineKeepers: 2, transientKeepers: 0, keeperRows: 7, tasks: 0, totalRuntimes: 4, available: true },
      configured: { keepers: 0, totalRuntimes: 0, source: 'none' },
      source: 'execution',
    })
  })
})

describe('runtimeHealthIsFresh', () => {
  it('rejects malformed or stale runtime health timestamps', () => {
    const now = Date.parse('2026-06-25T12:02:00Z')
    expect(runtimeHealthIsFresh(null, now)).toBe(true)
    expect(runtimeHealthIsFresh('not-a-date', now)).toBe(false)
    expect(runtimeHealthIsFresh('2026-06-25T12:00:00Z', now)).toBe(true)
    expect(runtimeHealthIsFresh('2026-06-25T11:59:59Z', now)).toBe(false)
  })
})

describe('runtimeCountSourceLabel', () => {
  it('maps count source ids to user-facing labels', () => {
    expect(runtimeCountSourceLabel('execution')).toBe('execution 상세')
    expect(runtimeCountSourceLabel('runtime-health')).toBe('runtime health')
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

describe('keeperRowLooksRunning', () => {
  it('uses keepalive_running as the strongest running signal', () => {
    expect(keeperRowLooksRunning({ status: 'offline', keepalive_running: true })).toBe(true)
    expect(keeperRowLooksRunning({ status: 'active', keepalive_running: false })).toBe(false)
  })

  it('falls back to runtime status only when keepalive truth is absent', () => {
    expect(keeperRowLooksRunning({ status: 'active' })).toBe(true)
    expect(keeperRowLooksRunning({ status: 'offline' })).toBe(false)
    expect(keeperRowLooksRunning({ phase: 'Paused', status: 'active' })).toBe(false)
  })
})

describe('formatActiveOverConfigured', () => {
  it('formats keeper counts as separate running-fiber and configured-keeper surfaces', () => {
    const counts = {
      live: { agents: 0, keepers: 2, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 2, tasks: 0, totalRuntimes: 2, available: true },
      configured: { keepers: 16, totalRuntimes: 16, source: 'namespace-truth' as const },
    }
    expect(formatActiveOverConfigured(counts, 'keeper')).toBe('keeper 실행 fiber 2 / configured keeper 16')
  })

  it('includes paused count in keeper formatting when paused keepers exist', () => {
    const counts = {
      live: { agents: 0, keepers: 4, pausedKeepers: 3, offlineKeepers: 0, transientKeepers: 0, keeperRows: 7, tasks: 0, totalRuntimes: 4, available: true },
      configured: { keepers: 24, totalRuntimes: 24, source: 'namespace-truth' as const },
    }
    expect(formatActiveOverConfigured(counts, 'keeper')).toBe('keeper 실행 fiber 4 / 일시정지 keeper 3 / configured keeper 24')
  })

  it('includes transient keeper count in keeper formatting when transient keepers exist', () => {
    const counts = {
      live: { agents: 0, keepers: 4, pausedKeepers: 1, offlineKeepers: 3, transientKeepers: 2, keeperRows: 10, tasks: 0, totalRuntimes: 4, available: true },
      configured: { keepers: 10, totalRuntimes: 10, source: 'namespace-truth' as const },
    }
    expect(formatActiveOverConfigured(counts, 'keeper'))
      .toBe('keeper 실행 fiber 4 / 일시정지 keeper 1 / 전이 keeper 2 / 오프라인 keeper 3 / configured keeper 10')
  })

  it('formats runtime totals without merging workspace agents into keeper fibers', () => {
    const counts = {
      live: { agents: 3, keepers: 2, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 2, tasks: 0, totalRuntimes: 5, available: true },
      configured: { keepers: 16, totalRuntimes: 20, source: 'namespace-truth' as const },
    }
    expect(formatActiveOverConfigured(counts, 'runtime')).toBe('keeper 실행 fiber 2 / workspace agents 3 / configured runtimes 20')
  })

  it('defaults kind to "keeper" when omitted', () => {
    const counts = {
      live: { agents: 0, keepers: 0, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 0, tasks: 0, totalRuntimes: 0, available: false },
      configured: { keepers: 0, totalRuntimes: 0, source: 'none' as const },
    }
    expect(formatActiveOverConfigured(counts)).toBe('keeper 실행 fiber 0 / configured keeper 0')
  })
})

describe('runtime count role helpers', () => {
  const counts = {
    live: { agents: 4, keepers: 4, pausedKeepers: 12, offlineKeepers: 0, transientKeepers: 0, keeperRows: 16, tasks: 0, totalRuntimes: 8, available: true },
    configured: { keepers: 16, totalRuntimes: 8, source: 'namespace-truth' as const },
  }

  it('keeps detail rows distinct from running runtime totals', () => {
    expect(keeperDetailRows(counts)).toBe(16)
    expect(runtimeDetailRows(counts)).toBe(20)
  })

  it('keeps configured keeper inventory as the expected detail-row floor', () => {
    const partialCounts = {
      live: { agents: 4, keepers: 4, pausedKeepers: 0, offlineKeepers: 0, transientKeepers: 0, keeperRows: 4, tasks: 0, totalRuntimes: 8, available: true },
      configured: { keepers: 16, totalRuntimes: 8, source: 'namespace-truth' as const },
    }
    expect(expectedKeeperDetailRows(partialCounts)).toBe(16)
    expect(expectedRuntimeDetailRows(partialCounts)).toBe(20)
  })

  it('formats the keeper count roles without losing paused inventory', () => {
    expect(formatKeeperCountBreakdown({
      liveKeepers: 4,
      pausedKeepers: 12,
      configuredKeepers: 16,
    })).toBe('keeper 실행 fiber 4 / 일시정지 keeper 12 / configured keeper 16')
  })

  it('formats transient keeper rows separately from offline inventory', () => {
    expect(formatKeeperCountBreakdown({
      liveKeepers: 4,
      pausedKeepers: 1,
      transientKeepers: 2,
      offlineKeepers: 3,
      configuredKeepers: 10,
    })).toBe('keeper 실행 fiber 4 / 일시정지 keeper 1 / 전이 keeper 2 / 오프라인 keeper 3 / configured keeper 10')
  })

  it('formats roster chips with transient rows visible in breakdowns', () => {
    const transientCounts = {
      live: { agents: 0, keepers: 4, pausedKeepers: 1, offlineKeepers: 3, transientKeepers: 2, keeperRows: 10, tasks: 0, totalRuntimes: 4, available: true },
      configured: { keepers: 10, totalRuntimes: 10, source: 'namespace-truth' as const },
    }
    expect(formatKeeperRosterCount(transientCounts))
      .toBe('keeper 행 10 / keeper 실행 fiber 4 / 일시정지 keeper 1 / 전이 keeper 2 / 오프라인 keeper 3 / configured keeper 10')
    expect(formatRuntimeRosterCount(transientCounts))
      .toBe('runtime 행 10 / keeper 실행 fiber 4 / workspace agents 0 / 일시정지 keeper 1 / 전이 keeper 2 / 오프라인 keeper 3 / configured keeper 10')
  })

  it('formats roster chips with detail rows, running runtimes, and configured inventory', () => {
    expect(formatKeeperRosterCount(counts)).toBe('keeper 행 16 / keeper 실행 fiber 4 / 일시정지 keeper 12 / configured keeper 16')
    expect(formatRuntimeRosterCount(counts)).toBe('runtime 행 20 / keeper 실행 fiber 4 / workspace agents 4 / 일시정지 keeper 12 / configured keeper 16')
  })

  it('surfaces offline keeper detail rows separately from running capacity', () => {
    const splitCounts = {
      live: { agents: 0, keepers: 2, pausedKeepers: 6, offlineKeepers: 9, transientKeepers: 0, keeperRows: 17, tasks: 0, totalRuntimes: 2, available: true },
      configured: { keepers: 17, totalRuntimes: 17, source: 'namespace-truth' as const },
    }

    expect(keeperDetailRows(splitCounts)).toBe(17)
    expect(formatKeeperRosterCount(splitCounts)).toBe('keeper 행 17 / keeper 실행 fiber 2 / 일시정지 keeper 6 / 오프라인 keeper 9 / configured keeper 17')
    expect(formatRuntimeRosterCount(splitCounts)).toBe('runtime 행 17 / keeper 실행 fiber 2 / workspace agents 0 / 일시정지 keeper 6 / 오프라인 keeper 9 / configured keeper 17')
  })

  it('formats command target sections as mission targets, not live runtime counts', () => {
    expect(formatCommandTargetSection('keeper', 16)).toBe('Mission keeper targets (16)')
    expect(formatCommandTargetSummary({ agents: 4, keepers: 16, sessions: 0 }))
      .toBe('명령 대상 에이전트 4 / 키퍼 16 / 세션 0')
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
