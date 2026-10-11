import type { ApiRequestError } from './core'

/** An operation lookup's explicit, schema-qualified missing-operation receipt. */
export class KeeperChatOperationMissingError extends Error {
  constructor(
    readonly keeperName: string,
    readonly operationId: string,
    cause: ApiRequestError,
  ) {
    super(cause.message, { cause })
    this.name = 'KeeperChatOperationMissingError'
  }
}
