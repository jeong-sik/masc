import { describe, it, expect } from 'vitest'
import type { UnifiedDiffRow } from '../../api/workspace'
import { buildSplitDiff } from './ide-diff-view'

const row = (
  kind: 'context' | 'add' | 'delete',
  oldLine: number | null,
  newLine: number | null,
  text: string,
): UnifiedDiffRow => ({ kind, oldLine, newLine, text })

describe('buildSplitDiff', () => {
  it('maps context rows to both sides', () => {
    const result = buildSplitDiff([
      row('context', 1, 1, 'unchanged'),
    ])
    expect(result).toHaveLength(1)
    expect(result[0]!.before?.kind).toBe('context')
    expect(result[0]!.after?.kind).toBe('context')
    expect(result[0]!.before?.text).toBe('unchanged')
  })

  it('pairs deletes with adds', () => {
    const result = buildSplitDiff([
      row('delete', 1, null, 'old line'),
      row('add', null, 1, 'new line'),
    ])
    expect(result).toHaveLength(1)
    expect(result[0]!.before?.kind).toBe('delete')
    expect(result[0]!.before?.text).toBe('old line')
    expect(result[0]!.after?.kind).toBe('add')
    expect(result[0]!.after?.text).toBe('new line')
  })

  it('handles unequal delete/add counts', () => {
    const result = buildSplitDiff([
      row('delete', 1, null, 'a'),
      row('delete', 2, null, 'b'),
      row('add', null, 1, 'c'),
    ])
    expect(result).toHaveLength(2)
    expect(result[0]!.before?.text).toBe('a')
    expect(result[0]!.after?.text).toBe('c')
    expect(result[1]!.before?.text).toBe('b')
    expect(result[1]!.after).toBeNull()
  })

  it('handles mixed context and changes', () => {
    const result = buildSplitDiff([
      row('context', 1, 1, 'keep'),
      row('delete', 2, null, 'gone'),
      row('add', null, 2, 'here'),
      row('context', 3, 3, 'keep2'),
    ])
    expect(result).toHaveLength(3)
    expect(result[0]!.before?.text).toBe('keep')
    expect(result[1]!.before?.text).toBe('gone')
    expect(result[1]!.after?.text).toBe('here')
    expect(result[2]!.before?.text).toBe('keep2')
  })

  it('returns empty for no rows', () => {
    expect(buildSplitDiff([])).toEqual([])
  })

  it('handles only adds', () => {
    const result = buildSplitDiff([
      row('add', null, 1, 'added'),
      row('add', null, 2, 'more'),
    ])
    expect(result).toHaveLength(2)
    expect(result[0]!.before).toBeNull()
    expect(result[0]!.after?.text).toBe('added')
    expect(result[1]!.before).toBeNull()
    expect(result[1]!.after?.text).toBe('more')
  })
})
