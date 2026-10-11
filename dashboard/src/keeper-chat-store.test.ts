import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { readKeeperDraft, writeKeeperDraft, clearKeeperDraft, readKeeperDraftSnapshot, updateKeeperDraft, _resetChatStoreForTests } from './keeper-chat-store'
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

  it('clears the canonical draft when written empty', () => {
    writeKeeperDraft('rondo', 'half typed')
    writeKeeperDraft('rondo', '')
    expect(readKeeperDraft('rondo')).toBe('')
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

describe('canonical composer snapshot', () => {
  afterEach(() => { _resetChatStoreForTests() })

  it('rejects a stale clear after newer text, media and voice are published', () => {
    writeKeeperDraft('echo', 'submitted draft')
    const submitted = readKeeperDraftSnapshot('echo')
    updateKeeperDraft('echo', draft => ({ ...draft, text: 'newer draft',
      attachments: [{ kind: 'url', id: 'image', name: 'image', url: 'https://example.com/image.png' }],
      voiceDraft: { transcript: 'newer voice' } }))
    expect(clearKeeperDraft('echo', undefined, submitted.revision)).toBe(false)
    expect(readKeeperDraftSnapshot('echo')).toMatchObject({ text: 'newer draft',
      attachments: [{ id: 'image' }], voiceDraft: { transcript: 'newer voice' } })
    expect(submitted.text).toBe('submitted draft')
    expect(submitted.attachments).toEqual([])
  })
})
