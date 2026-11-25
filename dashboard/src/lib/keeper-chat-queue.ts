import { ok, type Result } from './result'

interface QueueEntry {
  readonly operationId: string
  readonly sequence: string
}

export function queuedChatOperationsPath(keeper: string, afterSequence?: string): string {
  const query = new URLSearchParams({ state: 'queued' })
  if (afterSequence !== undefined) query.set('after_sequence', afterSequence)
  return `/api/v1/keepers/${encodeURIComponent(keeper)}/chat/operations?${query}`
}

export function decodeQueuedChatOperationPage<T extends QueueEntry>(
  value: unknown,
  afterSequence: string | undefined,
  decodeOperation: (row: unknown) => T,
): T[] {
  if (
    typeof value !== 'object' || value === null
    || !('schema' in value) || value.schema !== 'masc.keeper_chat_operations.list.v1'
    || !('state' in value) || value.state !== 'Queued'
    || !('operations' in value) || !Array.isArray(value.operations)
  ) {
    throw new Error('Keeper chat operation list has an invalid contract')
  }
  let cursor = afterSequence
  return value.operations.map((row) => {
    const operation = decodeOperation(row)
    if (cursor !== undefined && BigInt(operation.sequence) <= BigInt(cursor)) {
      throw new Error('Keeper chat operation page sequence did not advance')
    }
    cursor = operation.sequence
    return operation
  })
}

/** Live pages can report the same operation at a later sequence after a reorder. */
export async function readQueuedChatOperations<T extends QueueEntry, E>(
  readPage: (afterSequence: string | undefined) => Promise<Result<T[], E>>,
  afterSequence?: string,
): Promise<Result<T[], E>> {
  const operations = new Map<string, T>()
  let cursor = afterSequence
  for (;;) {
    const page = await readPage(cursor)
    if (!page.ok) return page
    if (page.value.length === 0) return ok([...operations.values()])
    for (const operation of page.value) {
      cursor = operation.sequence
      operations.delete(operation.operationId)
      operations.set(operation.operationId, operation)
    }
  }
}
