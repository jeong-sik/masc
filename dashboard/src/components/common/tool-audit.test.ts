import { describe, it, expect } from 'vitest'
import {
  linkedRuntimeState,
  toolAuditStateLabel,
  allowlistEmptyState,
  observedToolsEmptyState,
  auditMetadataState,
  linkedRecentToolsEmptyState,
} from './tool-audit'
import type { Keeper } from '../../types'

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'janitor',
    status: 'active',
    ...overrides,
  }
}

// ================================================================
// linkedRuntimeState
// ================================================================

describe('linkedRuntimeState', () => {
  it('returns unlinked for null', () => {
    expect(linkedRuntimeState(null)).toBe('unlinked')
  })

  it('returns unlinked for undefined', () => {
    expect(linkedRuntimeState(undefined)).toBe('unlinked')
  })

  it('health=offline 이면 offline', () => {
    const keeper = makeKeeper({ diagnostic: { health_state: 'offline' } } as Partial<Keeper>)
    expect(linkedRuntimeState(keeper)).toBe('offline')
  })

  it('phase=Stopped 면 offline', () => {
    const keeper = makeKeeper({ phase: 'Stopped' })
    expect(linkedRuntimeState(keeper)).toBe('offline')
  })

  it('health=healthy 면 online', () => {
    const keeper = makeKeeper({ diagnostic: { health_state: 'healthy' } } as Partial<Keeper>)
    expect(linkedRuntimeState(keeper)).toBe('online')
  })
})

// ================================================================
// toolAuditStateLabel
// ================================================================

describe('toolAuditStateLabel', () => {
  it('returns offline for offline', () => {
    expect(toolAuditStateLabel('offline')).toBe('offline')
  })

  it('returns none_recent for none_recent', () => {
    expect(toolAuditStateLabel('none_recent')).toBe('none_recent')
  })

  it('returns not_applicable for not_applicable', () => {
    expect(toolAuditStateLabel('not_applicable')).toBe('not_applicable')
  })

  it('returns unlinked for unlinked', () => {
    expect(toolAuditStateLabel('unlinked')).toBe('unlinked')
  })

  it('returns not_collected for not_collected', () => {
    expect(toolAuditStateLabel('not_collected')).toBe('not_collected')
  })

  it('returns not_collected for unknown', () => {
    expect(toolAuditStateLabel('custom' as any)).toBe('not_collected')
  })
})

// ================================================================
// allowlistEmptyState
// ================================================================

describe('allowlistEmptyState', () => {
  it('returns unlinked for null keeper', () => {
    expect(allowlistEmptyState(null)).toBe('unlinked')
  })

  it('returns offline for offline keeper', () => {
    const keeper = makeKeeper({ diagnostic: { health_state: 'offline' } } as Partial<Keeper>)
    expect(allowlistEmptyState(keeper)).toBe('offline')
  })

  it('returns not_collected for online keeper', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(allowlistEmptyState(keeper)).toBe('not_collected')
  })
})

// ================================================================
// observedToolsEmptyState
// ================================================================

describe('observedToolsEmptyState', () => {
  it('returns unlinked for null keeper', () => {
    expect(observedToolsEmptyState(null)).toBe('unlinked')
  })

  it('returns offline for offline keeper', () => {
    const keeper = makeKeeper({ diagnostic: { health_state: 'offline' } } as Partial<Keeper>)
    expect(observedToolsEmptyState(keeper)).toBe('offline')
  })

  it('returns none_recent when audit source is present', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(observedToolsEmptyState(keeper, 'realtime')).toBe('none_recent')
  })

  it('returns not_collected when audit source is empty', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(observedToolsEmptyState(keeper, '')).toBe('not_collected')
  })

  it('returns not_collected when audit source is null', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(observedToolsEmptyState(keeper, null)).toBe('not_collected')
  })

  it('returns not_collected when audit source is whitespace', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(observedToolsEmptyState(keeper, '   ')).toBe('not_collected')
  })

  it('returns not_collected when audit source is undefined', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(observedToolsEmptyState(keeper)).toBe('not_collected')
  })
})

// ================================================================
// auditMetadataState
// ================================================================

describe('auditMetadataState', () => {
  it('returns unlinked for null keeper', () => {
    expect(auditMetadataState(null)).toBe('unlinked')
  })

  it('returns offline for offline keeper', () => {
    const keeper = makeKeeper({ diagnostic: { health_state: 'offline' } } as Partial<Keeper>)
    expect(auditMetadataState(keeper)).toBe('offline')
  })

  it('returns none_recent when audit source is present', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(auditMetadataState(keeper, 'stream')).toBe('none_recent')
  })

  it('returns not_collected when audit source is empty', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(auditMetadataState(keeper, '')).toBe('not_collected')
  })

  it('returns not_collected when audit source is null', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(auditMetadataState(keeper, null)).toBe('not_collected')
  })
})

// ================================================================
// linkedRecentToolsEmptyState
// ================================================================

describe('linkedRecentToolsEmptyState', () => {
  it('returns unlinked for null keeper', () => {
    expect(linkedRecentToolsEmptyState(null)).toBe('unlinked')
  })

  it('returns offline for offline keeper', () => {
    const keeper = makeKeeper({ diagnostic: { health_state: 'offline' } } as Partial<Keeper>)
    expect(linkedRecentToolsEmptyState(keeper)).toBe('offline')
  })

  it('returns none_recent for online keeper', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(linkedRecentToolsEmptyState(keeper)).toBe('none_recent')
  })
})
