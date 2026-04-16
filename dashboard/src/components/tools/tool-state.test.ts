import { describe, it, expect } from 'vitest'
import {
  hasSurface,
  toolMatchesQuery,
  surfaceCountForFilter,
} from './tool-state'
import type { DashboardToolInventoryItem } from '../../api'

function makeItem(overrides: Partial<DashboardToolInventoryItem> = {}): DashboardToolInventoryItem {
  return {
    name: 'test_tool',
    description: 'A test tool',
    category: 'shell',
    category_description: null,
    enabled_in_current_mode: true,
    direct_call_allowed: true,
    required_permission: null,
    doc_refs: [],
    prompt_hints: [],
    surfaces: ['public_mcp'],
    visibility: 'visible',
    lifecycle: 'stable',
    implementationStatus: 'complete',
    tier: 'core',
    canonicalName: null,
    replacement: null,
    reason: null,
    ...overrides,
  }
}

// ================================================================
// hasSurface
// ================================================================

describe('hasSurface', () => {
  it('returns true when surface exists', () => {
    const item = makeItem({ surfaces: ['public_mcp', 'keeper_standard'] })
    expect(hasSurface(item, 'public_mcp')).toBe(true)
  })

  it('returns false when surface does not exist', () => {
    const item = makeItem({ surfaces: ['public_mcp'] })
    expect(hasSurface(item, 'keeper_standard')).toBe(false)
  })

  it('returns false for empty surfaces array', () => {
    const item = makeItem({ surfaces: [] })
    expect(hasSurface(item, 'public_mcp')).toBe(false)
  })

  it('handles null surfaces', () => {
    const item = makeItem({ surfaces: null as any })
    expect(hasSurface(item, 'public_mcp')).toBe(false)
  })

  it('handles undefined surfaces', () => {
    const item = makeItem({ surfaces: undefined as any })
    expect(hasSurface(item, 'public_mcp')).toBe(false)
  })
})

// ================================================================
// toolMatchesQuery
// ================================================================

describe('toolMatchesQuery', () => {
  it('returns true for empty query', () => {
    const item = makeItem()
    expect(toolMatchesQuery(item, '')).toBe(true)
  })

  it('returns true for whitespace-only query', () => {
    const item = makeItem()
    expect(toolMatchesQuery(item, '   ')).toBe(true)
  })

  it('matches tool name', () => {
    const item = makeItem({ name: 'shell_exec' })
    expect(toolMatchesQuery(item, 'shell')).toBe(true)
  })

  it('matches case-insensitively', () => {
    const item = makeItem({ name: 'Shell_Exec' })
    expect(toolMatchesQuery(item, 'shell')).toBe(true)
    expect(toolMatchesQuery(item, 'SHELL')).toBe(true)
  })

  it('matches description', () => {
    const item = makeItem({ description: 'Execute shell commands' })
    expect(toolMatchesQuery(item, 'execute')).toBe(true)
  })

  it('matches category', () => {
    const item = makeItem({ category: 'git' })
    expect(toolMatchesQuery(item, 'git')).toBe(true)
  })

  it('matches required_permission', () => {
    const item = makeItem({ required_permission: 'CanAdmin' })
    expect(toolMatchesQuery(item, 'admin')).toBe(true)
  })

  it('matches visibility', () => {
    const item = makeItem({ visibility: 'hidden' })
    expect(toolMatchesQuery(item, 'hidden')).toBe(true)
  })

  it('matches lifecycle', () => {
    const item = makeItem({ lifecycle: 'deprecated' })
    expect(toolMatchesQuery(item, 'deprecated')).toBe(true)
  })

  it('matches implementationStatus', () => {
    const item = makeItem({ implementationStatus: 'partial' })
    expect(toolMatchesQuery(item, 'partial')).toBe(true)
  })

  it('matches tier', () => {
    const item = makeItem({ tier: 'experimental' })
    expect(toolMatchesQuery(item, 'experimental')).toBe(true)
  })

  it('matches canonicalName', () => {
    const item = makeItem({ canonicalName: 'mcp__custom__tool' })
    expect(toolMatchesQuery(item, 'custom')).toBe(true)
  })

  it('matches replacement', () => {
    const item = makeItem({ replacement: 'new_tool' })
    expect(toolMatchesQuery(item, 'new_tool')).toBe(true)
  })

  it('matches reason', () => {
    const item = makeItem({ reason: 'superseded by v2' })
    expect(toolMatchesQuery(item, 'superseded')).toBe(true)
  })

  it('matches doc_refs', () => {
    const item = makeItem({ doc_refs: ['api-reference.md'] })
    expect(toolMatchesQuery(item, 'reference')).toBe(true)
  })

  it('matches prompt_hints', () => {
    const item = makeItem({ prompt_hints: ['use for debugging'] })
    expect(toolMatchesQuery(item, 'debugging')).toBe(true)
  })

  it('matches surfaces', () => {
    const item = makeItem({ surfaces: ['keeper_privileged'] })
    expect(toolMatchesQuery(item, 'privileged')).toBe(true)
  })

  it('returns false when no field matches', () => {
    const item = makeItem({ name: 'shell_exec', description: 'Run commands' })
    expect(toolMatchesQuery(item, 'nonexistent')).toBe(false)
  })

  it('trims query before matching', () => {
    const item = makeItem({ name: 'shell_exec' })
    expect(toolMatchesQuery(item, '  shell  ')).toBe(true)
  })
})

// ================================================================
// surfaceCountForFilter
// ================================================================

describe('surfaceCountForFilter', () => {
  it('returns total length for all filter', () => {
    const items = [makeItem(), makeItem(), makeItem()]
    expect(surfaceCountForFilter(items, 'all')).toBe(3)
  })

  it('counts public_mcp items', () => {
    const items = [
      makeItem({ surfaces: ['public_mcp'] }),
      makeItem({ surfaces: ['keeper_standard'] }),
      makeItem({ surfaces: ['public_mcp'] }),
    ]
    expect(surfaceCountForFilter(items, 'public_mcp')).toBe(2)
  })

  it('counts agent items', () => {
    const items = [
      makeItem({ surfaces: ['spawned_agent_mcp'] }),
      makeItem({ surfaces: ['public_mcp'] }),
    ]
    expect(surfaceCountForFilter(items, 'agent')).toBe(1)
  })

  it('counts keeper items', () => {
    const items = [
      makeItem({ surfaces: ['keeper_standard'] }),
      makeItem({ surfaces: ['keeper_privileged'] }),
      makeItem({ surfaces: ['public_mcp'] }),
    ]
    expect(surfaceCountForFilter(items, 'keeper')).toBe(2)
  })

  it('counts internal items', () => {
    const items = [
      makeItem({ surfaces: ['local_worker'] }),
      makeItem({ surfaces: ['privileged_executor'] }),
      makeItem({ surfaces: ['public_mcp'] }),
    ]
    expect(surfaceCountForFilter(items, 'internal')).toBe(2)
  })

  it('returns 0 for empty inventory', () => {
    expect(surfaceCountForFilter([], 'all')).toBe(0)
    expect(surfaceCountForFilter([], 'public_mcp')).toBe(0)
  })

  it('handles items with null surfaces', () => {
    const items = [
      makeItem({ surfaces: null as any }),
      makeItem({ surfaces: ['public_mcp'] }),
    ]
    expect(surfaceCountForFilter(items, 'public_mcp')).toBe(1)
  })

  it('counts item with multiple matching surfaces once', () => {
    const items = [
      makeItem({ surfaces: ['keeper_standard', 'keeper_privileged'] }),
    ]
    expect(surfaceCountForFilter(items, 'keeper')).toBe(1)
  })
})
