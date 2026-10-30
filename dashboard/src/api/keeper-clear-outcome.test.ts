import { describe, expect, it } from 'vitest'
import { keeperClearOutcome } from './keeper-lifecycle'

// The clear route answers ok when it emptied the conversation and when it
// deleted a checkpoint it could not decode. Only the second leaves no history
// to recover, so the dashboard has to tell them apart from `detail`.
describe('keeperClearOutcome', () => {
  it('reads a cleared conversation', () => {
    expect(keeperClearOutcome({ name: 'alpha', checkpoint_found: true, preserve_system_prompt: true }))
      .toEqual({ kind: 'history_cleared' })
  })

  it('reads a deleted undecodable checkpoint', () => {
    expect(keeperClearOutcome({
      undecodable_checkpoint_removed: { checkpoint_path: '/p/alpha.json', decode_error: 'bad json' },
      checkpoint_found: true,
    })).toEqual({ kind: 'undecodable_checkpoint_removed' })
  })

  it('does not read a deletion out of a field that is not an object', () => {
    for (const bad of [null, true, 'removed', 3, []]) {
      expect(keeperClearOutcome({ undecodable_checkpoint_removed: bad }).kind).toBe('history_cleared')
    }
  })

  it('treats a detail that is not an object as a plain clear', () => {
    for (const detail of [undefined, null, 'cleared', 7]) {
      expect(keeperClearOutcome(detail).kind).toBe('history_cleared')
    }
  })
})
