import { beforeEach, describe, expect, it, vi } from 'vitest'

const post = vi.fn()
const get = vi.fn()

vi.mock('./core', async importOriginal => {
  const actual = await importOriginal<typeof import('./core')>()
  return {
    ...actual,
    get: (...args: unknown[]) => get(...args),
    post: (...args: unknown[]) => post(...args),
  }
})

import { ApiRequestError } from './core'
import { answerKeeperAsk, AskAnswerConflict } from './keeper-asks'

describe('answerKeeperAsk', () => {
  beforeEach(() => {
    post.mockReset()
    get.mockReset()
  })

  it('treats HTTP 500 with recorded === true as accepted with delivered === false', async () => {
    post.mockRejectedValue(
      new ApiRequestError({
        method: 'POST',
        path: '/api/v1/keepers/ask-answer',
        status: 500,
        responseData: {
          recorded: true,
          delivered: false,
          ask_id: 'a1',
          answer_count: 2,
          open_remaining: 0,
        },
      }),
    )
    const result = await answerKeeperAsk({ ask_id: 'a1', answers: [] })
    expect(result).toEqual({
      askId: 'a1',
      answerCount: 2,
      openRemaining: 0,
      delivered: false,
    })
  })

  it('rethrows HTTP 500 when state is recording_unconfirmed', async () => {
    const err = new ApiRequestError({
      method: 'POST',
      path: '/api/v1/keepers/ask-answer',
      status: 500,
      responseData: {
        recorded: true,
        state: 'recording_unconfirmed',
        ask_id: 'a1',
      },
    })
    post.mockRejectedValue(err)
    await expect(answerKeeperAsk({ ask_id: 'a1', answers: [] })).rejects.toBe(err)
  })

  it('maps HTTP 409 to AskAnswerConflict', async () => {
    post.mockRejectedValue(
      new ApiRequestError({
        method: 'POST',
        path: '/api/v1/keepers/ask-answer',
        status: 409,
        detail: 'already answered',
      }),
    )
    await expect(answerKeeperAsk({ ask_id: 'a1', answers: [] })).rejects.toBeInstanceOf(
      AskAnswerConflict,
    )
  })
})
