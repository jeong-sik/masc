import { describe, expect, it } from 'vitest'

import { isAskAnswerRefusedForShutdown } from './keeper-asks'

describe('isAskAnswerRefusedForShutdown', () => {
  it('recognizes a 503 shutdown refusal that leaves the answer unrecorded', () => {
    expect(isAskAnswerRefusedForShutdown(503, {
      state: 'keeper_shutting_down',
      recorded: false,
      ask_id: 'a1',
    })).toBe(true)
  })

  it('keeps unrelated failures out of the shutdown path', () => {
    expect(isAskAnswerRefusedForShutdown(503, { error: 'booting' })).toBe(false)
    expect(isAskAnswerRefusedForShutdown(500, { state: 'keeper_shutting_down' })).toBe(false)
  })
})
