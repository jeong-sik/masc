import { describe, expect, it } from 'vitest'
import { ApiRequestError } from './core'
import { keeperChatOperationRefusalCode } from './keeper-chat-operation-refusal'

const CANCEL_PATH = '/api/v1/keepers/echo/chat/operations/op-1/cancel'

function refused(responseData: unknown): ApiRequestError {
  return new ApiRequestError({ method: 'POST', path: CANCEL_PATH, status: 409, responseData })
}

describe('keeperChatOperationRefusalCode', () => {
  it('reads the code of a chat operation refusal body', () => {
    expect(keeperChatOperationRefusalCode(refused({
      schema: 'masc.keeper_chat_operation.error.v1',
      error: 'not_queued',
      message: 'The operation is no longer queued.',
      incident_id: 'incident-1',
    }))).toBe('not_queued')
  })

  it('reads no code from a body of another schema', () => {
    expect(keeperChatOperationRefusalCode(refused({ error: 'not_queued' }))).toBeNull()
    expect(keeperChatOperationRefusalCode(refused({
      schema: 'masc.keeper_chat_operation.v1', error: 'not_queued',
    }))).toBeNull()
  })

  it('reads no code from the text of an error', () => {
    // The code is a field of the refusal body, never a word found in a message.
    expect(keeperChatOperationRefusalCode(new Error(`POST ${CANCEL_PATH}: not_queued`))).toBeNull()
    expect(keeperChatOperationRefusalCode(new ApiRequestError({
      method: 'POST', path: CANCEL_PATH, status: 409, detail: 'not_queued', errorCode: 'not_queued',
    }))).toBeNull()
  })
})
