// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { render, h } from 'preact'
import { InventoryRow } from './tool-inventory-row'
import type { DashboardToolInventoryItem } from '../../api'

function makeItem(overrides: Partial<DashboardToolInventoryItem> = {}): DashboardToolInventoryItem {
  return {
    name: 'Test Tool',
    description: 'A test tool',
    category: 'test',
    visibility: 'public',
    lifecycle: 'stable',
    implementationStatus: 'complete',
    direct_call_allowed: true,
    required_permission: null,
    canonicalName: null,
    replacement: null,
    reason: null,
    doc_refs: [],
    surfaces: [],
    ...overrides,
  } as DashboardToolInventoryItem
}

describe('InventoryRow', () => {
  it('renders name and description', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem() }), container)
    expect(container.textContent).toContain('Test Tool')
    expect(container.textContent).toContain('A test tool')
  })

  it('shows category label', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ category: 'utils' }) }), container)
    expect(container.textContent).toContain('utils')
  })

  it('shows uncategorized with hint', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ category: 'uncategorized' }) }), container)
    expect(container.textContent).toContain('미분류')
    expect(container.textContent).toContain('서버 미지정')
  })

  it('shows direct call allowed', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ direct_call_allowed: true }) }), container)
    expect(container.textContent).toContain('허용')
  })

  it('shows direct call blocked', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ direct_call_allowed: false }) }), container)
    expect(container.textContent).toContain('차단')
  })

  it('shows required permission when present', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ required_permission: 'admin' }) }), container)
    expect(container.textContent).toContain('admin')
  })

  it('shows 없음 when required_permission is null', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ required_permission: null }) }), container)
    expect(container.textContent).toContain('없음')
  })

  it('shows reason when present', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ reason: 'Deprecated in favor of v2' }) }), container)
    expect(container.textContent).toContain('Deprecated in favor of v2')
  })

  it('does not show reason section when reason is null', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ reason: null }) }), container)
    const reasonEl = container.querySelector('.tool-inventory-reason')
    expect(reasonEl).toBeNull()
  })

  it('shows canonicalName when present', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ canonicalName: 'canonical.tool.name' }) }), container)
    expect(container.textContent).toContain('canonical.tool.name')
  })

  it('shows replacement when present', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ replacement: 'other-tool' }) }), container)
    expect(container.textContent).toContain('other-tool')
  })

  it('shows doc_refs when present', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ doc_refs: ['doc1', 'doc2'] }) }), container)
    expect(container.textContent).toContain('doc1')
    expect(container.textContent).toContain('doc2')
  })

  it('renders surfaces badges', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ surfaces: ['public_mcp'] }) }), container)
    expect(container.textContent).toContain('public_mcp')
  })

  it('renders lifecycle badge with warn tone for deprecated', () => {
    const container = document.createElement('div')
    render(h(InventoryRow, { item: makeItem({ lifecycle: 'deprecated' }) }), container)
    expect(container.textContent).toContain('deprecated')
  })
})
