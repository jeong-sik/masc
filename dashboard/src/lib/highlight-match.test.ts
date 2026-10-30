import { describe, it, expect } from 'vitest'
import { highlightMatch, highlightSafe } from './highlight-match'

// The <mark> branches are emitted as htm/preact VNode objects. We don't
// assert on their internal shape here (that couples us to htm internals);
// we just check string chunks via typeof + that non-string entries are
// objects in the expected positions.
function isMark(part: unknown): boolean {
  return typeof part === 'object' && part !== null
}

describe('highlightMatch', () => {
  it('returns [text] for empty needle', () => {
    const parts = highlightMatch('hello world', '')
    expect(parts).toEqual(['hello world'])
  })

  it('returns [text] for whitespace-only needle', () => {
    const parts = highlightMatch('hello world', '   ')
    expect(parts).toEqual(['hello world'])
  })

  it('returns [text] when no match is found', () => {
    const parts = highlightMatch('hello world', 'xyz')
    expect(parts).toEqual(['hello world'])
  })

  it('wraps a single mid-string match into 3 parts', () => {
    const parts = highlightMatch('hello world', 'lo w')
    expect(parts).toHaveLength(3)
    expect(parts[0]).toBe('hel')
    expect(isMark(parts[1])).toBe(true)
    expect(parts[2]).toBe('orld')
  })

  it('alternates parts for multiple non-adjacent matches', () => {
    const parts = highlightMatch('foo bar foo baz foo', 'foo')
    // raw prefix/suffix around 3 matches (suffix for last is empty when
    // match is at end; here last match is followed by nothing so no
    // trailing chunk). Expect: mark, " bar ", mark, " baz ", mark.
    expect(parts).toHaveLength(5)
    expect(isMark(parts[0])).toBe(true)
    expect(parts[1]).toBe(' bar ')
    expect(isMark(parts[2])).toBe(true)
    expect(parts[3]).toBe(' baz ')
    expect(isMark(parts[4])).toBe(true)
  })

  it('collapses adjacent matches into a single highlight', () => {
    // "abab" with needle "ab" → two adjacent matches [0,2) and [2,4).
    const parts = highlightMatch('abab', 'ab')
    expect(parts).toHaveLength(1)
    expect(isMark(parts[0])).toBe(true)
  })

  it('collapses overlapping matches into a single highlight', () => {
    // "aaaa" with needle "aa" → indexOf from 0,1,2 → ranges
    // [0,2),[1,3),[2,4), all overlap → merge to [0,4).
    const parts = highlightMatch('aaaa', 'aa')
    expect(parts).toHaveLength(1)
    expect(isMark(parts[0])).toBe(true)
  })

  it('preserves original casing when match is case-insensitive', () => {
    // We can't reach into the htm VNode to inspect the inner string
    // directly without coupling to internals, so we use a shape check:
    // original text "Test" should appear as a single <mark> chunk only.
    const parts = highlightMatch('Test', 'test')
    expect(parts).toHaveLength(1)
    expect(isMark(parts[0])).toBe(true)
    // Sanity: lowercased needle should also match the capitalised text.
    const parts2 = highlightMatch('abc TEST xyz', 'test')
    expect(parts2).toHaveLength(3)
    expect(parts2[0]).toBe('abc ')
    expect(isMark(parts2[1])).toBe(true)
    expect(parts2[2]).toBe(' xyz')
  })

  it('emits no empty prefix when match is at the start', () => {
    const parts = highlightMatch('foobar', 'foo')
    expect(parts).toHaveLength(2)
    expect(isMark(parts[0])).toBe(true)
    expect(parts[1]).toBe('bar')
  })

  it('emits no empty suffix when match is at the end', () => {
    const parts = highlightMatch('foobar', 'bar')
    expect(parts).toHaveLength(2)
    expect(parts[0]).toBe('foo')
    expect(isMark(parts[1])).toBe(true)
  })

  it('returns [""] for empty text', () => {
    expect(highlightMatch('', 'anything')).toEqual([''])
  })
})

describe('highlightSafe', () => {
  it('returns [""] for null', () => {
    expect(highlightSafe(null, 'x')).toEqual([''])
  })

  it('returns [""] for undefined', () => {
    expect(highlightSafe(undefined, 'x')).toEqual([''])
  })

  it('delegates to highlightMatch for non-empty text', () => {
    const parts = highlightSafe('hello', 'ell')
    expect(parts).toHaveLength(3)
    expect(parts[0]).toBe('h')
    expect(isMark(parts[1])).toBe(true)
    expect(parts[2]).toBe('o')
  })
})
