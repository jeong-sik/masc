import { isRecord } from '../components/common/normalize'
import { ApiRequestError } from './core'

const KEEPER_CHAT_OPERATION_ERROR_SCHEMA = 'masc.keeper_chat_operation.error.v1'

/** The machine code of a chat operation request the server refused, read from
 *  the refusal body the chat operation routes answer with. null when `err` is
 *  not such a refusal: a transport failure, a timeout, or another route's error
 *  body. The codes are the server's `Keeper_chat_public_error.code` spellings. */
export function keeperChatOperationRefusalCode(err: unknown): string | null {
  if (!(err instanceof ApiRequestError)) return null
  const body = err.responseData
  if (!isRecord(body) || body.schema !== KEEPER_CHAT_OPERATION_ERROR_SCHEMA) return null
  return typeof body.error === 'string' ? body.error : null
}
