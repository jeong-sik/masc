import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { readKeeperDraft, writeKeeperDraft, clearKeeperDraft, _draftCountForTests, _resetChatStoreForTests } from './keeper-chat-store'
import { setStoredToken, clearStoredToken, currentStoredTokenRevision } from './api/core'

describe('keeper-chat-store draft persistence', () => {
  beforeEach(() => { _resetChatStoreForTests() })
  afterEach(() => { _resetChatStoreForTests() })

  it('reads empty for an unknown keeper', () => {
    expect(readKeeperDraft('ghost')).toBe('')
  })

  it('round-trips a draft per keeper without leaking across keepers', () => {
    writeKeeperDraft('rondo', '소주에 갑오징어')
    writeKeeperDraft('qa-king', '리뷰 부탁')
    // Each keeper keeps its own draft — no cross-keeper leak (the old single
    // shared draft would have shown one keeper's text in another's composer).
    expect(readKeeperDraft('rondo')).toBe('소주에 갑오징어')
    expect(readKeeperDraft('qa-king')).toBe('리뷰 부탁')
  })

  it('deletes the entry when written empty (no blank accumulation after send)', () => {
    writeKeeperDraft('rondo', 'half typed')
    expect(_draftCountForTests()).toBe(1)
    writeKeeperDraft('rondo', '')
    expect(readKeeperDraft('rondo')).toBe('')
    // The entry is removed, not stored as '' — readKeeperDraft alone cannot
    // distinguish the two, so assert the map actually shrank.
    expect(_draftCountForTests()).toBe(0)
  })

  it('clearKeeperDraft drops a keeper draft', () => {
    writeKeeperDraft('rondo', 'pending')
    clearKeeperDraft('rondo')
    expect(readKeeperDraft('rondo')).toBe('')
  })

  it('trims the key so whitespace variants address the same draft', () => {
    writeKeeperDraft('rondo', 'x')
    expect(readKeeperDraft('  rondo  ')).toBe('x')
  })

  it('ignores a blank-key write', () => {
    writeKeeperDraft('   ', 'nope')
    expect(readKeeperDraft('')).toBe('')
  })
})

describe('draft authentication ownership', () => {
  afterEach(() => { clearStoredToken(); _resetChatStoreForTests() })

  it('retains old authored input without exposing it to the new epoch or letting late cleanup clear new input', () => {
    setStoredToken('fixture-old')
    const oldOwner = currentStoredTokenRevision()
    writeKeeperDraft('echo', 'old authored draft', oldOwner)
    setStoredToken('fixture-new')
    expect(readKeeperDraft('echo')).toBe('')
    writeKeeperDraft('echo', 'new authored draft')
    writeKeeperDraft('echo', 'late old authored draft', oldOwner)
    expect(readKeeperDraft('echo')).toBe('new authored draft')
    expect(readKeeperDraft('echo', oldOwner)).toBe('late old authored draft')
    clearKeeperDraft('echo', oldOwner)
    expect(readKeeperDraft('echo')).toBe('new authored draft')
  })
})
