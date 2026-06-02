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
    status: 'healthy',
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

  it('returns offline when agent exists=false', () => {
    const keeper = makeKeeper({ agent: { exists: false } })
    expect(linkedRuntimeState(keeper)).toBe('offline')
  })

  it('returns offline for offline status', () => {
    const keeper = makeKeeper({ status: 'offline' })
    expect(linkedRuntimeState(keeper)).toBe('offline')
  })

  it('returns offline for inactive status', () => {
    const keeper = makeKeeper({ status: 'inactive' })
    expect(linkedRuntimeState(keeper)).toBe('offline')
  })

  it('returns online for healthy keeper', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(linkedRuntimeState(keeper)).toBe('online')
  })

  it('returns online for running keeper', () => {
    const keeper = makeKeeper({ status: 'running' })
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
    const keeper = makeKeeper({ status: 'offline' })
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
    const keeper = makeKeeper({ status: 'offline' })
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
    const keeper = makeKeeper({ status: 'offline' })
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
    const keeper = makeKeeper({ status: 'offline' })
    expect(linkedRecentToolsEmptyState(keeper)).toBe('offline')
  })

  it('returns none_recent for online keeper', () => {
    const keeper = makeKeeper({ status: 'healthy' })
    expect(linkedRecentToolsEmptyState(keeper)).toBe('none_recent')
  })
})
