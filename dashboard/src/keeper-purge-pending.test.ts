import { describe, it, expect, beforeEach } from 'vitest'
import {
  keeperPurgePending,
  markKeeperPurgePending,
  purgePendingAfterRefresh,
} from './store'

describe('keeper purge pending', () => {
  beforeEach(() => {
    keeperPurgePending.value = new Set<string>()
  })

  it('marks a submitted purge so the row can show it is in flight', () => {
    markKeeperPurgePending('canary-a')
    expect([...keeperPurgePending.value]).toEqual(['canary-a'])
  })

  it('ignores a blank name and does not re-emit for a name already pending', () => {
    markKeeperPurgePending('   ')
    expect(keeperPurgePending.value.size).toBe(0)

    markKeeperPurgePending('canary-a')
    const first = keeperPurgePending.value
    markKeeperPurgePending('canary-a')
    expect(keeperPurgePending.value).toBe(first)
  })

  // The server deletes asynchronously, so the refresh that follows the submit
  // still returns the keeper. Only its later disappearance means the purge
  // finished — there is no completion event to listen for.
  it('keeps a name while the refresh still returns that keeper', () => {
    const pending = new Set(['canary-a'])
    expect(purgePendingAfterRefresh(pending, [{ name: 'canary-a' }])).toBe(pending)
  })

  it('drops a name once the refresh stops returning that keeper', () => {
    const next = purgePendingAfterRefresh(new Set(['canary-a', 'canary-b']), [
      { name: 'canary-b' },
    ])
    expect([...next]).toEqual(['canary-b'])
  })

  it('returns the same set when nothing is pending so no render is triggered', () => {
    const empty = new Set<string>()
    expect(purgePendingAfterRefresh(empty, [{ name: 'canary-a' }])).toBe(empty)
  })
})
