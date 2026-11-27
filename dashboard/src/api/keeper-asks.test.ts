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
import { answerKeeperAsk, AskAnswerConflict, AskAnswerKeeperShuttingDown } from './keeper-asks'
import type { AnswerRequestBody } from '../lib/keeper-ask-draft'

const requestBody: AnswerRequestBody = { name: 'keeper-a', ask_id: 'a1', answers: [] }

describe('answerKeeperAsk', () => {
  beforeEach(() => {
    post.mockReset()
    get.mockReset()
  })

  it('maps HTTP 503 keeper_shutting_down to AskAnswerKeeperShuttingDown', async () => {
    post.mockRejectedValue(
      new ApiRequestError({
        method: 'POST',
        path: '/api/v1/keepers/ask-answer',
        status: 503,
        responseData: {
          state: 'keeper_shutting_down',
          recorded: false,
          ask_id: 'a1',
        },
      }),
    )
    await expect(answerKeeperAsk(requestBody)).rejects.toBeInstanceOf(AskAnswerKeeperShuttingDown)
  })

  it('rethrows HTTP 503 without the shutdown state', async () => {
    const err = new ApiRequestError({
      method: 'POST',
      path: '/api/v1/keepers/ask-answer',
      status: 503,
      responseData: { error: 'booting' },
    })
    post.mockRejectedValue(err)
    await expect(answerKeeperAsk(requestBody)).rejects.toBe(err)
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
    await expect(answerKeeperAsk(requestBody)).rejects.toBe(err)
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
    await expect(answerKeeperAsk(requestBody)).rejects.toBeInstanceOf(
      AskAnswerConflict,
    )
  })
})
