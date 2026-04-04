import { describe, expect, it } from 'vitest'

import { visibleNamespaceLabel } from './activity-graph'

describe('visibleNamespaceLabel', () => {
  it('hides empty and default namespaces', () => {
    expect(visibleNamespaceLabel(null)).toBeNull()
    expect(visibleNamespaceLabel(undefined)).toBeNull()
    expect(visibleNamespaceLabel('')).toBeNull()
    expect(visibleNamespaceLabel('   ')).toBeNull()
    expect(visibleNamespaceLabel('default')).toBeNull()
    expect(visibleNamespaceLabel(' default ')).toBeNull()
  })

  it('returns trimmed non-default namespaces', () => {
    expect(visibleNamespaceLabel('project-a')).toBe('project-a')
    expect(visibleNamespaceLabel(' project-b ')).toBe('project-b')
  })
})
